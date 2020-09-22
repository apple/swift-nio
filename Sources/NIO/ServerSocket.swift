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
    private let cleanupOnClose: Bool

    public final class func bootstrap(protocolFamily: NIOBSDSocket.ProtocolFamily, host: String, port: Int) throws -> ServerSocket {
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
    init(protocolFamily: NIOBSDSocket.ProtocolFamily, setNonBlocking: Bool = false) throws {
        let sock = try BaseSocket.makeSocket(protocolFamily: protocolFamily, type: .stream, setNonBlocking: setNonBlocking)
        switch protocolFamily {
        case .unix:
            cleanupOnClose = true
        default:
            cleanupOnClose = false
        }
        try super.init(socket: sock)
    }

    /// Create a new instance.
    ///
    /// - parameters:
    ///     - descriptor: The _Unix file descriptor_ representing the bound socket.
    ///     - setNonBlocking: Set non-blocking mode on the socket.
    /// - throws: An `IOError` if socket is invalid.
    #if !os(Windows)
        @available(*, deprecated, renamed: "init(socket:setNonBlocking:)")
        convenience init(descriptor: CInt, setNonBlocking: Bool = false) throws {
          try self.init(socket: descriptor, setNonBlocking: setNonBlocking)
        }
    #endif

    /// Create a new instance.
    ///
    /// - parameters:
    ///     - descriptor: The _Unix file descriptor_ representing the bound socket.
    ///     - setNonBlocking: Set non-blocking mode on the socket.
    /// - throws: An `IOError` if socket is invalid.
    init(socket: NIOBSDSocket.Handle, setNonBlocking: Bool = false) throws {
        cleanupOnClose = false  // socket already bound, owner must clean up
        try super.init(socket: socket)
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
            _ = try NIOBSDSocket.listen(socket: $0, backlog: backlog)
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
            let result = try NIOBSDSocket.accept(socket: fd, address: nil, address_len: nil)
            #endif

            guard let fd = result else {
                return nil
            }
            let sock = try Socket(socket: fd)
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
    
    /// Close the socket.
    ///
    /// After the socket was closed all other methods will throw an `IOError` when called.
    ///
    /// - throws: An `IOError` if the operation failed.
    override func close() throws {
        let maybePathname = self.cleanupOnClose ? (try? self.localAddress().pathname) : nil
        try super.close()
        if let socketPath = maybePathname {
            try BaseSocket.cleanupSocket(unixDomainSocketPath: socketPath)
        }
    }
}
