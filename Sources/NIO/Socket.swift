//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// The container used for writing multiple buffers via `writev`.
public typealias IOVector = iovec

// TODO: scattering support
/* final but tests */ class Socket: BaseSocket {

    /// The maximum number of bytes to write per `writev` call.
    static var writevLimitBytes: Int {
        #if arch(arm) // 32-bit, Raspi/AppleWatch/etc
            // Note(hh): This is not a _proper_ fix, but necessary because
            //           other places extend on that. Should be fine in
            //           practice on 32-bit platforms.
            return Int(Int32.max / 4)
        #else
            return Int(Int32.max)
        #endif
    }

    /// The maximum number of `IOVector`s to write per `writev` call.
    static let writevLimitIOVectors: Int = Posix.UIO_MAXIOV

    /// Create a new instance.
    ///
    /// - parameters:
    ///     - protocolFamily: The protocol family to use (usually `AF_INET6` or `AF_INET`).
    ///     - type: The type of the socket to create.
    ///     - setNonBlocking: Set non-blocking mode on the socket.
    /// - throws: An `IOError` if creation of the socket failed.
    init(protocolFamily: CInt, type: CInt, setNonBlocking: Bool = false) throws {
        let sock = try BaseSocket.newSocket(protocolFamily: protocolFamily, type: type, setNonBlocking: setNonBlocking)
        super.init(descriptor: sock)
    }

    /// Create a new instance out of an already established socket.
    ///
    /// - parameters:
    ///     - descriptor: The existing socket descriptor.
    ///     - setNonBlocking: Set non-blocking mode on the socket.
    /// - throws: An `IOError` if could not change the socket into non-blocking
    init(descriptor: CInt, setNonBlocking: Bool) throws {
        super.init(descriptor: descriptor)
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
    override init(descriptor: CInt) {
        super.init(descriptor: descriptor)
    }

    /// Connect to the `SocketAddress`.
    ///
    /// - parameters:
    ///     - address: The `SocketAddress` to which the connection should be established.
    /// - returns: `true` if the connection attempt completes, `false` if `finishConnect` must be called later to complete the connection attempt.
    /// - throws: An `IOError` if the operation failed.
    func connect(to address: SocketAddress) throws -> Bool {
        switch address {
        case .v4(let addr):
            return try self.connectSocket(addr: addr.address)
        case .v6(let addr):
            return try self.connectSocket(addr: addr.address)
        case .unixDomainSocket(let addr):
            return try self.connectSocket(addr: addr.address)
        }
    }

    /// Private helper function to handle connection attempts.
    private func connectSocket<T>(addr: T) throws -> Bool {
        return try withUnsafeFileDescriptor { fd in
            var addr = addr
            return try withUnsafePointer(to: &addr) { ptr in
                try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    try Posix.connect(descriptor: fd, addr: ptr, size: socklen_t(MemoryLayout<T>.size))
                }
            }
        }
    }

    /// Finish a previous non-blocking `connect` operation.
    ///
    /// - throws: An `IOError` if the operation failed.
    func finishConnect() throws {
        let result: Int32 = try getOption(level: SOL_SOCKET, name: SO_ERROR)
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
        return try withUnsafeFileDescriptor { fd in
            try Posix.write(descriptor: fd, pointer: pointer.baseAddress!, size: pointer.count)
        }
    }

    /// Write data to the remote peer (gathering writes).
    ///
    /// - parameters:
    ///     - iovecs: The `IOVector`s to write.
    /// - returns: The `IOResult` which indicates how much data could be written and if the operation returned before all could be written (because the socket is in non-blocking mode).
    /// - throws: An `IOError` if the operation failed.
    func writev(iovecs: UnsafeBufferPointer<IOVector>) throws -> IOResult<Int> {
        return try withUnsafeFileDescriptor { fd in
            try Posix.writev(descriptor: fd, iovecs: iovecs)
        }
    }

    /// Send data to a destination.
    ///
    /// - parameters:
    ///     - pointer: Pointer (and size) to the data to send.
    ///     - destinationPtr: The destination to which the data should be sent.
    /// - returns: The `IOResult` which indicates how much data could be written and if the operation returned before all could be written (because the socket is in non-blocking mode).
    /// - throws: An `IOError` if the operation failed.
    func sendto(pointer: UnsafeRawBufferPointer, destinationPtr: UnsafePointer<sockaddr>, destinationSize: socklen_t) throws -> IOResult<Int> {
        return try withUnsafeFileDescriptor { fd in
            try Posix.sendto(descriptor: fd, pointer: UnsafeMutableRawPointer(mutating: pointer.baseAddress!),
                             size: pointer.count, destinationPtr: destinationPtr,
                             destinationSize: destinationSize)
        }
    }

    /// Read data from the socket.
    ///
    /// - parameters:
    ///     - pointer: The pointer (and size) to the storage into which the data should be read.
    /// - returns: The `IOResult` which indicates how much data could be read and if the operation returned before all could be read (because the socket is in non-blocking mode).
    /// - throws: An `IOError` if the operation failed.
    func read(pointer: UnsafeMutableRawBufferPointer) throws -> IOResult<Int> {
        return try withUnsafeFileDescriptor { fd in
            try Posix.read(descriptor: fd, pointer: pointer.baseAddress!, size: pointer.count)
        }
    }

    /// Receive data from the socket.
    ///
    /// - parameters:
    ///     - pointer: The pointer (and size) to the storage into which the data should be read.
    ///     - storage: The address from which the data was received
    ///     - storageLen: The size of the storage itself.
    /// - returns: The `IOResult` which indicates how much data could be received and if the operation returned before all could be received (because the socket is in non-blocking mode).
    /// - throws: An `IOError` if the operation failed.
    func recvfrom(pointer: UnsafeMutableRawBufferPointer, storage: inout sockaddr_storage, storageLen: inout socklen_t) throws -> IOResult<(Int)> {
        return try withUnsafeFileDescriptor { fd in
            try storage.withMutableSockAddr { (storagePtr, _) in
                try Posix.recvfrom(descriptor: fd, pointer: pointer.baseAddress!,
                                   len: pointer.count,
                                   addr: storagePtr,
                                   addrlen: &storageLen)
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
    func sendFile(fd: Int32, offset: Int, count: Int) throws -> IOResult<Int> {
        return try withUnsafeFileDescriptor { desc in
            try Posix.sendfile(descriptor: desc, fd: fd, offset: off_t(offset), count: count)
        }
    }

    /// Receive `MMsgHdr`s.
    ///
    /// - parameters:
    ///     - msgs: The pointer to the `MMsgHdr`s into which the received message will be stored.
    /// - returns: The `IOResult` which indicates how many messages could be received and if the operation returned before all messages could be received (because the socket is in non-blocking mode).
    /// - throws: An `IOError` if the operation failed.
    func recvmmsg(msgs: UnsafeMutableBufferPointer<MMsgHdr>) throws -> IOResult<Int> {
        return try withUnsafeFileDescriptor { fd in
            try Posix.recvmmsg(sockfd: fd, msgvec: msgs.baseAddress!, vlen: CUnsignedInt(msgs.count), flags: 0, timeout: nil)
        }
    }

    /// Send `MMsgHdr`s.
    ///
    /// - parameters:
    ///     - msgs: The pointer to the `MMsgHdr`s which will be send.
    /// - returns: The `IOResult` which indicates how many messages could be send and if the operation returned before all messages could be send (because the socket is in non-blocking mode).
    /// - throws: An `IOError` if the operation failed.
    func sendmmsg(msgs: UnsafeMutableBufferPointer<MMsgHdr>) throws -> IOResult<Int> {
        return try withUnsafeFileDescriptor { fd in
            try Posix.sendmmsg(sockfd: fd, msgvec: msgs.baseAddress!, vlen: CUnsignedInt(msgs.count), flags: 0)
        }
    }

    /// Shutdown the socket.
    ///
    /// - parameters:
    ///     - how: the mode of `Shutdown`.
    /// - throws: An `IOError` if the operation failed.
    func shutdown(how: Shutdown) throws {
        return try withUnsafeFileDescriptor { fd in
            try Posix.shutdown(descriptor: fd, how: how)
        }
    }
}
