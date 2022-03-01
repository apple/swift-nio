//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

/// The container used for writing multiple buffers via `writev`.
typealias IOVector = iovec

// TODO: scattering support
/* final but tests */ class Socket: BaseSocket, SocketProtocol {
    typealias SocketType = Socket

    /// The maximum number of bytes to write per `writev` call.
    static var writevLimitBytes = Int(Int32.max)

    /// The maximum number of `IOVector`s to write per `writev` call.
    static let writevLimitIOVectors: Int = Posix.UIO_MAXIOV

    /// Create a new instance.
    ///
    /// - parameters:
    ///     - protocolFamily: The protocol family to use (usually `AF_INET6` or `AF_INET`).
    ///     - type: The type of the socket to create.
    ///     - setNonBlocking: Set non-blocking mode on the socket.
    /// - throws: An `IOError` if creation of the socket failed.
    init(protocolFamily: NIOBSDSocket.ProtocolFamily, type: NIOBSDSocket.SocketType, setNonBlocking: Bool = false) throws {
        let sock = try BaseSocket.makeSocket(protocolFamily: protocolFamily, type: type, setNonBlocking: setNonBlocking)
        try super.init(socket: sock)
    }

    /// Create a new instance out of an already established socket.
    ///
    /// - parameters:
    ///     - descriptor: The existing socket descriptor.
    ///     - setNonBlocking: Set non-blocking mode on the socket.
    /// - throws: An `IOError` if could not change the socket into non-blocking
    #if !os(Windows)
        @available(*, deprecated, renamed: "init(socket:setNonBlocking:)")
        convenience init(descriptor: CInt, setNonBlocking: Bool) throws {
            try self.init(socket: descriptor, setNonBlocking: setNonBlocking)
        }
    #endif

    /// Create a new instance out of an already established socket.
    ///
    /// - parameters:
    ///     - descriptor: The existing socket descriptor.
    ///     - setNonBlocking: Set non-blocking mode on the socket.
    /// - throws: An `IOError` if could not change the socket into non-blocking
    init(socket: NIOBSDSocket.Handle, setNonBlocking: Bool) throws {
        try super.init(socket: socket)
        if setNonBlocking {
            try self.setNonBlocking()
        }
    }

    /// Create a new instance.
    ///
    /// The ownership of the passed in descriptor is transferred to this class. A user must call `close` to close the underlying
    /// file descriptor once it's not needed / used anymore.
    ///
    /// - parameters:
    ///     - descriptor: The file descriptor to wrap.
    #if !os(Windows)
        @available(*, deprecated, renamed: "init(socket:)")
        convenience init(descriptor: CInt) throws {
            try self.init(socket: descriptor)
        }
    #endif

    /// Create a new instance.
    ///
    /// The ownership of the passed in descriptor is transferred to this class. A user must call `close` to close the underlying
    /// file descriptor once it's not needed / used anymore.
    ///
    /// - parameters:
    ///     - descriptor: The file descriptor to wrap.
    override init(socket: NIOBSDSocket.Handle) throws {
        try super.init(socket: socket)
    }

    /// Connect to the `SocketAddress`.
    ///
    /// - parameters:
    ///     - address: The `SocketAddress` to which the connection should be established.
    /// - returns: `true` if the connection attempt completes, `false` if `finishConnect` must be called later to complete the connection attempt.
    /// - throws: An `IOError` if the operation failed.
    func connect(to address: SocketAddress) throws -> Bool {
        return try withUnsafeHandle { fd in
            return try address.withSockAddr { (ptr, size) in
                return try NIOBSDSocket.connect(socket: fd, address: ptr,
                                                address_len: socklen_t(size))
            }
        }
    }

    /// Finish a previous non-blocking `connect` operation.
    ///
    /// - throws: An `IOError` if the operation failed.
    func finishConnect() throws {
        let result: Int32 = try getOption(level: .socket, name: .so_error)
        if result != 0 {
            throw IOError(errnoCode: result, reason: "finishing a non-blocking connect failed")
        }
    }

    /// Write data to the remote peer.
    ///
    /// - parameters:
    ///     - pointer: Pointer (and size) to data to write.
    /// - returns: The `IOResult` which indicates how much data could be written and if the operation returned before all could be written (because the socket is in non-blocking mode).
    /// - throws: An `IOError` if the operation failed.
    func write(pointer: UnsafeRawBufferPointer) throws -> IOResult<Int> {
        return try withUnsafeHandle {
            try NIOBSDSocket.send(socket: $0, buffer: pointer.baseAddress!,
                                  length: pointer.count)
        }
    }

    /// Write data to the remote peer (gathering writes).
    ///
    /// - parameters:
    ///     - iovecs: The `IOVector`s to write.
    /// - returns: The `IOResult` which indicates how much data could be written and if the operation returned before all could be written (because the socket is in non-blocking mode).
    /// - throws: An `IOError` if the operation failed.
    func writev(iovecs: UnsafeBufferPointer<IOVector>) throws -> IOResult<Int> {
        return try withUnsafeHandle {
            try Posix.writev(descriptor: $0, iovecs: iovecs)
        }
    }

    /// Send data to a destination.
    ///
    /// - parameters:
    ///     - pointer: Pointer (and size) to the data to send.
    ///     - destinationPtr: The destination to which the data should be sent.
    ///     - destinationSize: The size of the destination address given.
    ///     - controlBytes: Extra `cmsghdr` information.
    /// - returns: The `IOResult` which indicates how much data could be written and if the operation returned before all could be written
    /// (because the socket is in non-blocking mode).
    /// - throws: An `IOError` if the operation failed.
    func sendmsg(pointer: UnsafeRawBufferPointer,
                 destinationPtr: UnsafePointer<sockaddr>,
                 destinationSize: socklen_t,
                 controlBytes: UnsafeMutableRawBufferPointer) throws -> IOResult<Int> {
        // Dubious const casts - it should be OK as there is no reason why this should get mutated
        // just bad const declaration below us.
        var vec = iovec(iov_base: UnsafeMutableRawPointer(mutating: pointer.baseAddress!), iov_len: numericCast(pointer.count))
        let notConstCorrectDestinationPtr = UnsafeMutableRawPointer(mutating: destinationPtr)

        return try withUnsafeHandle { handle in
            return try withUnsafeMutablePointer(to: &vec) { vecPtr in
#if os(Windows)
                var messageHeader =
                    WSAMSG(name: notConstCorrectDestinationPtr
                                    .assumingMemoryBound(to: sockaddr.self),
                           namelen: destinationSize,
                           lpBuffers: vecPtr,
                           dwBufferCount: 1,
                           Control: WSABUF(len: ULONG(controlBytes.count),
                                           buf: controlBytes.baseAddress?
                                                    .bindMemory(to: CHAR.self,
                                                                capacity: controlBytes.count)),
                           dwFlags: 0)
#else
                var messageHeader = msghdr(msg_name: notConstCorrectDestinationPtr,
                                           msg_namelen: destinationSize,
                                           msg_iov: vecPtr,
                                           msg_iovlen: 1,
                                           msg_control: controlBytes.baseAddress,
                                           msg_controllen: .init(controlBytes.count),
                                           msg_flags: 0)
#endif
                return try NIOBSDSocket.sendmsg(socket: handle, msgHdr: &messageHeader, flags: 0)
            }
        }
    }

    /// Read data from the socket.
    ///
    /// - parameters:
    ///     - pointer: The pointer (and size) to the storage into which the data should be read.
    /// - returns: The `IOResult` which indicates how much data could be read and if the operation returned before all could be read (because the socket is in non-blocking mode).
    /// - throws: An `IOError` if the operation failed.
    func read(pointer: UnsafeMutableRawBufferPointer) throws -> IOResult<Int> {
        return try withUnsafeHandle {
            try Posix.read(descriptor: $0, pointer: pointer.baseAddress!, size: pointer.count)
        }
    }

    /// Receive data from the socket, along with aditional control information.
    ///
    /// - parameters:
    ///     - pointer: The pointer (and size) to the storage into which the data should be read.
    ///     - storage: The address from which the data was received
    ///     - storageLen: The size of the storage itself.
    ///     - controlBytes: A buffer in memory for use receiving control bytes. This parameter will be modified to hold any data actually received.
    /// - returns: The `IOResult` which indicates how much data could be received and if the operation returned before all the data could be received
    ///     (because the socket is in non-blocking mode)
    /// - throws: An `IOError` if the operation failed.
    func recvmsg(pointer: UnsafeMutableRawBufferPointer,
                 storage: inout sockaddr_storage,
                 storageLen: inout socklen_t,
                 controlBytes: inout UnsafeReceivedControlBytes) throws -> IOResult<Int> {
        var vec = iovec(iov_base: pointer.baseAddress, iov_len: numericCast(pointer.count))

        return try withUnsafeMutablePointer(to: &vec) { vecPtr in
            return try storage.withMutableSockAddr { (sockaddrPtr, _) in
#if os(Windows)
                var messageHeader =
                    WSAMSG(name: sockaddrPtr, namelen: storageLen,
                           lpBuffers: vecPtr, dwBufferCount: 1,
                           Control: WSABUF(len: ULONG(controlBytes.controlBytesBuffer.count),
                                           buf: controlBytes.controlBytesBuffer.baseAddress?
                                                    .bindMemory(to: CHAR.self,
                                                                capacity: controlBytes.controlBytesBuffer.count)),
                           dwFlags: 0)
                defer {
                    // We need to write back the length of the message.
                    storageLen = messageHeader.namelen
                }
#else
                var messageHeader = msghdr(msg_name: sockaddrPtr,
                                           msg_namelen: storageLen,
                                           msg_iov: vecPtr,
                                           msg_iovlen: 1,
                                           msg_control: controlBytes.controlBytesBuffer.baseAddress,
                                           msg_controllen: .init(controlBytes.controlBytesBuffer.count),
                                           msg_flags: 0)
                defer {
                    // We need to write back the length of the message.
                    storageLen = messageHeader.msg_namelen
                }
#endif

                let result = try withUnsafeMutablePointer(to: &messageHeader) { messageHeader in
                    return try withUnsafeHandle { fd in
                        return try NIOBSDSocket.recvmsg(socket: fd, msgHdr: messageHeader, flags: 0)
                    }
                }
                
                // Only look at the control bytes if all is good.
                if case .processed = result {
                    controlBytes.receivedControlMessages = UnsafeControlMessageCollection(messageHeader: messageHeader)
                }
                
                return result
            }
        }
    }

    /// Send the content of a file descriptor to the remote peer (if possible a zero-copy strategy is applied).
    ///
    /// - parameters:
    ///     - fd: The file descriptor of the file to send.
    ///     - offset: The offset in the file.
    ///     - count: The number of bytes to send.
    /// - returns: The `IOResult` which indicates how much data could be send and if the operation returned before all could be send (because the socket is in non-blocking mode).
    /// - throws: An `IOError` if the operation failed.
    func sendFile(fd: CInt, offset: Int, count: Int) throws -> IOResult<Int> {
        return try withUnsafeHandle {
            try NIOBSDSocket.sendfile(socket: $0, fd: fd, offset: off_t(offset),
                                      len: off_t(count))
        }
    }

    /// Receive `MMsgHdr`s.
    ///
    /// - parameters:
    ///     - msgs: The pointer to the `MMsgHdr`s into which the received message will be stored.
    /// - returns: The `IOResult` which indicates how many messages could be received and if the operation returned before all messages could be received (because the socket is in non-blocking mode).
    /// - throws: An `IOError` if the operation failed.
    func recvmmsg(msgs: UnsafeMutableBufferPointer<MMsgHdr>) throws -> IOResult<Int> {
        return try withUnsafeHandle {
            try NIOBSDSocket.recvmmsg(socket: $0, msgvec: msgs.baseAddress!,
                                      vlen: CUnsignedInt(msgs.count), flags: 0,
                                      timeout: nil)
        }
    }

    /// Send `MMsgHdr`s.
    ///
    /// - parameters:
    ///     - msgs: The pointer to the `MMsgHdr`s which will be send.
    /// - returns: The `IOResult` which indicates how many messages could be send and if the operation returned before all messages could be send (because the socket is in non-blocking mode).
    /// - throws: An `IOError` if the operation failed.
    func sendmmsg(msgs: UnsafeMutableBufferPointer<MMsgHdr>) throws -> IOResult<Int> {
        return try withUnsafeHandle {
            try NIOBSDSocket.sendmmsg(socket: $0, msgvec: msgs.baseAddress!,
                                      vlen: CUnsignedInt(msgs.count), flags: 0)
        }
    }

    /// Shutdown the socket.
    ///
    /// - parameters:
    ///     - how: the mode of `Shutdown`.
    /// - throws: An `IOError` if the operation failed.
    func shutdown(how: Shutdown) throws {
        return try withUnsafeHandle {
            try NIOBSDSocket.shutdown(socket: $0, how: how)
        }
    }
}
