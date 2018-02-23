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
final class ServerSocket: BaseSocket {
    public class func bootstrap(protocolFamily: Int32, host: String, port: Int) throws -> ServerSocket {
        let socket = try ServerSocket(protocolFamily: protocolFamily)
        try socket.bind(to: SocketAddress.newAddressResolving(host: host, port: port))
        try socket.listen()
        return socket
    }
    
    /// Create a new instance.
    ///
    /// - parameters:
    ///     - protocolFamily: The protocol family to use (usually `AF_INET6` or `AF_INET`).
    /// - throws: An `IOError` if creation of the socket failed.
    init(protocolFamily: Int32) throws {
        let sock = try BaseSocket.newSocket(protocolFamily: protocolFamily, type: Posix.SOCK_STREAM)
        super.init(descriptor: sock)
    }
    
    /// Start to listen for new connections.
    ///
    /// - parameters:
    ///     - backlog: The backlog to use.
    /// - throws: An `IOError` if creation of the socket failed.
    func listen(backlog: Int32 = 128) throws {
        _ = try Posix.listen(descriptor: descriptor, backlog: backlog)
    }
    
    /// Accept a new connection
    ///
    /// - returns: A `Socket` once a new connection was established or `nil` if this `ServerSocket` is in non-blocking mode and there is no new connection that can be accepted when this method is called.
    /// - throws: An `IOError` if the operation failed.
    func accept() throws -> Socket? {
        var acceptAddr = sockaddr_in()
        var addrSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        
        let result = try withUnsafeMutablePointer(to: &acceptAddr) { ptr in
            try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                try Posix.accept(descriptor: self.descriptor, addr: ptr, len: &addrSize)
            }
        }
        
        guard let fd = result else {
            return nil
        }
        return Socket(descriptor: fd)
    }
}
