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

import CNIOLinux
import CNIOOpenBSD
import NIOCore

#if canImport(WinSDK)
import WinSDK
#endif

/// The container used for writing multiple buffers via `writev`.
#if canImport(WinSDK)
typealias IOVector = WSABUF
#else
typealias IOVector = iovec
#endif

// TODO: scattering support
class Socket: BaseSocket, SocketProtocol {
    typealias SocketType = Socket

    /// The maximum number of bytes to write per `writev` call.
    static let writevLimitBytes = Int(Int32.max)

    /// The maximum number of `IOVector`s to write per `writev` call.
    static let writevLimitIOVectors: Int = Posix.UIO_MAXIOV

    /// Create a new instance.
    ///
    /// - Parameters:
    ///   - protocolFamily: The protocol family to use (usually `AF_INET6` or `AF_INET`).
    ///   - type: The type of the socket to create.
    ///   - protocolSubtype: The subtype of the protocol, corresponding to the `protocolSubtype`
    ///         argument to the socket syscall. Defaults to 0.
    ///   - setNonBlocking: Set non-blocking mode on the socket.
    /// - Throws: An `IOError` if creation of the socket failed.
    init(
        protocolFamily: NIOBSDSocket.ProtocolFamily,
        type: NIOBSDSocket.SocketType,
        protocolSubtype: NIOBSDSocket.ProtocolSubtype = .default,
        setNonBlocking: Bool = false
    ) throws {
        let sock = try BaseSocket.makeSocket(
            protocolFamily: protocolFamily,
            type: type,
            protocolSubtype: protocolSubtype,
            setNonBlocking: setNonBlocking
        )
        try super.init(socket: sock)
    }

    /// Create a new instance out of an already established socket.
    ///
    /// - Parameters:
    ///   - descriptor: The existing socket descriptor.
    ///   - setNonBlocking: Set non-blocking mode on the socket.
    /// - Throws: An `IOError` if could not change the socket into non-blocking
    #if !os(Windows)
    @available(*, deprecated, renamed: "init(socket:setNonBlocking:)")
    convenience init(descriptor: CInt, setNonBlocking: Bool) throws {
        try self.init(socket: descriptor, setNonBlocking: setNonBlocking)
    }
    #endif

    /// Create a new instance out of an already established socket.
    ///
    /// - Parameters:
    ///   - descriptor: The existing socket descriptor.
    ///   - setNonBlocking: Set non-blocking mode on the socket.
    /// - Throws: An `IOError` if could not change the socket into non-blocking
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
    /// - Parameters:
    ///   - descriptor: The file descriptor to wrap.
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
    /// - Parameters:
    ///   - descriptor: The file descriptor to wrap.
    override init(socket: NIOBSDSocket.Handle) throws {
        try super.init(socket: socket)
    }

    /// Connect to the `SocketAddress`.
    ///
    /// - Parameters:
    ///   - address: The `SocketAddress` to which the connection should be established.
    /// - Returns: `true` if the connection attempt completes, `false` if `finishConnect` must be called later to complete the connection attempt.
    /// - Throws: An `IOError` if the operation failed.
    func connect(to address: SocketAddress) throws -> Bool {
        try withUnsafeHandle { fd in
            try address.withSockAddr { (ptr, size) in
                try NIOBSDSocket.connect(
                    socket: fd,
                    address: ptr,
                    address_len: socklen_t(size)
                )
            }
        }
    }

    func connect(to address: VsockAddress) throws -> Bool {
        try withUnsafeHandle { fd in
            try address.withSockAddr { (ptr, size) in
                try NIOBSDSocket.connect(
                    socket: fd,
                    address: ptr,
                    address_len: socklen_t(size)
                )
            }
        }
    }

    /// Finish a previous non-blocking `connect` operation.
    ///
    /// - Throws: An `IOError` if the operation failed.
    func finishConnect() throws {
        let result: Int32 = try getOption(level: .socket, name: .so_error)
        if result != 0 {
            throw IOError(errnoCode: result, reason: "finishing a non-blocking connect failed")
        }
    }

    /// Write data to the remote peer.
    ///
    /// - Parameters:
    ///   - pointer: Pointer (and size) to data to write.
    /// - Returns: The `IOResult` which indicates how much data could be written and if the operation returned before all could be written (because the socket is in non-blocking mode).
    /// - Throws: An `IOError` if the operation failed.
    func write(pointer: UnsafeRawBufferPointer) throws -> IOResult<Int> {
        try withUnsafeHandle {
            try NIOBSDSocket.send(
                socket: $0,
                buffer: pointer.baseAddress!,
                length: pointer.count
            )
        }
    }

    /// Write data to the remote peer (gathering writes).
    ///
    /// - Parameters:
    ///   - iovecs: The `IOVector`s to write.
    /// - Returns: The `IOResult` which indicates how much data could be written and if the operation returned before all could be written (because the socket is in non-blocking mode).
    /// - Throws: An `IOError` if the operation failed.
    func writev(iovecs: UnsafeBufferPointer<IOVector>) throws -> IOResult<Int> {
        try withUnsafeHandle {
            try NIOBSDSocket.writev(socket: $0, iovecs: iovecs)
        }
    }

    /// Send data to a destination.
    ///
    /// - Parameters:
    ///   - pointer: Pointer (and size) to the data to send.
    ///   - destinationPtr: The destination to which the data should be sent.
    ///   - destinationSize: The size of the destination address given.
    ///   - controlBytes: Extra `cmsghdr` information.
    /// - Returns: The `IOResult` which indicates how much data could be written and if the operation returned before all could be written
    /// (because the socket is in non-blocking mode).
    /// - Throws: An `IOError` if the operation failed.
    func sendmsg(
        pointer: UnsafeRawBufferPointer,
        destinationPtr: UnsafePointer<sockaddr>?,
        destinationSize: socklen_t,
        controlBytes: UnsafeMutableRawBufferPointer
    ) throws -> IOResult<Int> {
        // Dubious const casts - it should be OK as there is no reason why this should get mutated
        // just bad const declaration below us.
        var vec = IOVector(
            iov_base: UnsafeMutableRawPointer(mutating: pointer.baseAddress!),
            iov_len: numericCast(pointer.count)
        )
        let notConstCorrectDestinationPtr = UnsafeMutableRawPointer(mutating: destinationPtr)

        return try self.withUnsafeHandle { handle in
            try withUnsafeMutablePointer(to: &vec) { vecPtr in
                var messageHeader = msghdr()
                messageHeader.msg_name = notConstCorrectDestinationPtr
                messageHeader.msg_namelen = destinationSize
                messageHeader.msg_iov = vecPtr
                messageHeader.msg_iovlen = 1
                messageHeader.control_ptr = controlBytes
                messageHeader.msg_flags = 0
                return try NIOBSDSocket.sendmsg(socket: handle, msgHdr: &messageHeader, flags: 0)
            }
        }
    }

    /// Read data from the socket.
    ///
    /// - Parameters:
    ///   - pointer: The pointer (and size) to the storage into which the data should be read.
    /// - Returns: The `IOResult` which indicates how much data could be read and if the operation returned before all could be read (because the socket is in non-blocking mode).
    /// - Throws: An `IOError` if the operation failed.
    func read(pointer: UnsafeMutableRawBufferPointer) throws -> IOResult<Int> {
        try withUnsafeHandle { (handle) -> IOResult<Int> in
            #if os(Windows)
            try Windows.recv(socket: handle, pointer: pointer.baseAddress!, size: Int32(pointer.count), flags: 0)
            #else
            try Posix.read(descriptor: handle, pointer: pointer.baseAddress!, size: pointer.count)
            #endif
        }
    }

    /// Receive data from the socket, along with aditional control information.
    ///
    /// - Parameters:
    ///   - pointer: The pointer (and size) to the storage into which the data should be read.
    ///   - storage: The address from which the data was received
    ///   - storageLen: The size of the storage itself.
    ///   - controlBytes: A buffer in memory for use receiving control bytes. This parameter will be modified to hold any data actually received.
    /// - Returns: The `IOResult` which indicates how much data could be received and if the operation returned before all the data could be received
    ///     (because the socket is in non-blocking mode)
    /// - Throws: An `IOError` if the operation failed.
    func recvmsg(
        pointer: UnsafeMutableRawBufferPointer,
        storage: inout sockaddr_storage,
        storageLen: inout socklen_t,
        controlBytes: inout UnsafeReceivedControlBytes
    ) throws -> IOResult<Int> {
        var vec = IOVector(iov_base: pointer.baseAddress, iov_len: numericCast(pointer.count))

        return try withUnsafeMutablePointer(to: &vec) { vecPtr in
            try storage.withMutableSockAddr { (sockaddrPtr, _) in
                var messageHeader = msghdr()
                messageHeader.msg_name = .init(sockaddrPtr)
                messageHeader.msg_namelen = storageLen
                messageHeader.msg_iov = vecPtr
                messageHeader.msg_iovlen = 1
                messageHeader.control_ptr = controlBytes.controlBytesBuffer
                messageHeader.msg_flags = 0
                defer {
                    // We need to write back the length of the message.
                    storageLen = messageHeader.msg_namelen
                }

                let result = try withUnsafeMutablePointer(to: &messageHeader) { messageHeader in
                    try withUnsafeHandle { fd in
                        try NIOBSDSocket.recvmsg(socket: fd, msgHdr: messageHeader, flags: 0)
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
    /// - Parameters:
    ///   - fd: The file descriptor of the file to send.
    ///   - offset: The offset in the file.
    ///   - count: The number of bytes to send.
    /// - Returns: The `IOResult` which indicates how much data could be send and if the operation returned before all could be send (because the socket is in non-blocking mode).
    /// - Throws: An `IOError` if the operation failed.
    func sendFile(fd: CInt, offset: Int, count: Int) throws -> IOResult<Int> {
        try withUnsafeHandle {
            try NIOBSDSocket.sendfile(
                socket: $0,
                fd: fd,
                offset: off_t(offset),
                len: off_t(count)
            )
        }
    }

    /// Receive `MMsgHdr`s.
    ///
    /// - Parameters:
    ///   - msgs: The pointer to the `MMsgHdr`s into which the received message will be stored.
    /// - Returns: The `IOResult` which indicates how many messages could be received and if the operation returned before all messages could be received (because the socket is in non-blocking mode).
    /// - Throws: An `IOError` if the operation failed.
    func recvmmsg(msgs: UnsafeMutableBufferPointer<MMsgHdr>) throws -> IOResult<Int> {
        try withUnsafeHandle {
            try NIOBSDSocket.recvmmsg(
                socket: $0,
                msgvec: msgs.baseAddress!,
                vlen: CUnsignedInt(msgs.count),
                flags: 0,
                timeout: nil
            )
        }
    }

    /// Send `MMsgHdr`s.
    ///
    /// - Parameters:
    ///   - msgs: The pointer to the `MMsgHdr`s which will be send.
    /// - Returns: The `IOResult` which indicates how many messages could be send and if the operation returned before all messages could be send (because the socket is in non-blocking mode).
    /// - Throws: An `IOError` if the operation failed.
    func sendmmsg(msgs: UnsafeMutableBufferPointer<MMsgHdr>) throws -> IOResult<Int> {
        try withUnsafeHandle {
            try NIOBSDSocket.sendmmsg(
                socket: $0,
                msgvec: msgs.baseAddress!,
                vlen: CUnsignedInt(msgs.count),
                flags: 0
            )
        }
    }

    /// Shutdown the socket.
    ///
    /// - Parameters:
    ///   - how: the mode of `Shutdown`.
    /// - Throws: An `IOError` if the operation failed.
    func shutdown(how: Shutdown) throws {
        try withUnsafeHandle {
            try NIOBSDSocket.shutdown(socket: $0, how: how)
        }
    }

    /// Sets the value for the 'UDP_SEGMENT' socket option.
    func setUDPSegmentSize(_ segmentSize: CInt) throws {
        try self.withUnsafeHandle {
            try NIOBSDSocket.setUDPSegmentSize(segmentSize, socket: $0)
        }
    }

    /// Returns the value of the 'UDP_SEGMENT' socket option.
    func getUDPSegmentSize() throws -> CInt {
        try self.withUnsafeHandle {
            try NIOBSDSocket.getUDPSegmentSize(socket: $0)
        }
    }

    /// Sets the value for the 'UDP_GRO' socket option.
    func setUDPReceiveOffload(_ enabled: Bool) throws {
        try self.withUnsafeHandle {
            try NIOBSDSocket.setUDPReceiveOffload(enabled, socket: $0)
        }
    }

    /// Returns the value of the 'UDP_GRO' socket option.
    func getUDPReceiveOffload() throws -> Bool {
        try self.withUnsafeHandle {
            try NIOBSDSocket.getUDPReceiveOffload(socket: $0)
        }
    }
}
