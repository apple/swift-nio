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

final class ServerSocket: BaseSocket {
    public class func bootstrap(protocolFamily: Int32, host: String, port: Int32) throws -> ServerSocket {
        let socket = try ServerSocket(protocolFamily: protocolFamily)
        try socket.bind(to: SocketAddress.newAddressResolving(host: host, port: port))
        try socket.listen()
        return socket
    }
    
    init(protocolFamily: Int32) throws {
        let sock = try BaseSocket.newSocket(protocolFamily: protocolFamily, type: Posix.SOCK_STREAM)
        super.init(descriptor: sock)
    }
    
    func listen(backlog: Int32 = 128) throws {
        _ = try Posix.listen(descriptor: descriptor, backlog: backlog)
    }
    
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
