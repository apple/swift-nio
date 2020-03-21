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

/// A server socket that can accept new connections.
/* final but tests */ class ServerSocket: BaseSocket, ServerSocketProtocol {
    typealias SocketType = ServerSocket

    public final class func bootstrap(protocolFamily: Int32, host: String, port: Int) throws -> ServerSocket {
        let socket = try ServerSocket(protocolFamily: protocolFamily)
        try socket.bind(to: SocketAddress.makeAddressResolvingHost(host, port: port))
        try socket.listen()
        return socket
    }

    /// Create a new instance.
    ///
    /// - parameters:
    ///     - protocolFamily: The protocol family to use (usually `AF_INET6` or `AF_INET`).
    ///     - setNonBlocking: Set non-blocking mode on the socket.
    /// - throws: An `IOError` if creation of the socket failed.
    init(protocolFamily: Int32, setNonBlocking: Bool = false) throws {
        let sock = try BaseSocket.makeSocket(protocolFamily: protocolFamily, type: Posix.SOCK_STREAM, setNonBlocking: setNonBlocking)
        try super.init(descriptor: sock)
    }

    /// Create a new instance.
    ///
    /// - parameters:
    ///     - descriptor: The _Unix file descriptor_ representing the bound socket.
    ///     - setNonBlocking: Set non-blocking mode on the socket.
    /// - throws: An `IOError` if socket is invalid.
    init(descriptor: CInt, setNonBlocking: Bool = false) throws {
        try super.init(descriptor: descriptor)
        if setNonBlocking {
            try self.setNonBlocking()
        }
    }

    /// Start to listen for new connections.
    ///
    /// - parameters:
    ///     - backlog: The backlog to use.
    /// - throws: An `IOError` if creation of the socket failed.
    func listen(backlog: Int32 = 128) throws {
        try withUnsafeHandle {
            _ = try Posix.listen(descriptor: $0, backlog: backlog)
        }
    }

    /// Accept a new connection
    ///
    /// - parameters:
    ///     - setNonBlocking: set non-blocking mode on the returned `Socket`. On Linux this will use accept4 with SOCK_NONBLOCK to save a system call.
    /// - returns: A `Socket` once a new connection was established or `nil` if this `ServerSocket` is in non-blocking mode and there is no new connection that can be accepted when this method is called.
    /// - throws: An `IOError` if the operation failed.
    func accept(setNonBlocking: Bool = false) throws -> Socket? {
        return try withUnsafeHandle { fd in
            #if os(Linux)
            let flags: Int32
            if setNonBlocking {
                flags = Linux.SOCK_NONBLOCK
            } else {
                flags = 0
            }
            let result = try Linux.accept4(descriptor: fd, addr: nil, len: nil, flags: flags)
            #else
            let result = try Posix.accept(descriptor: fd, addr: nil, len: nil)
            #endif

            guard let fd = result else {
                return nil
            }
            let sock = try Socket(descriptor: fd)
            #if !os(Linux)
            if setNonBlocking {
                do {
                    try sock.setNonBlocking()
                } catch {
                    // best effort
                    try? sock.close()
                    throw error
                }
            }
            #endif
            return sock
        }
    }
}
