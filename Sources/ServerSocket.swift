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

import Foundation


#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    import Darwin
#elseif os(Linux)
    import Glibc
#endif


public class ServerSocket: BaseSocket {
    
    public class func bootstrap(host: String, port: Int32) throws -> ServerSocket {
        let socket = try ServerSocket();
        try socket.bind(address: SocketAddresses.newAddress(for: host, on: port)!)
        try socket.listen(backlog: 128)
        return socket
    }
    
    init() throws {
#if os(Linux)
        let fd = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
#else
        let fd = Darwin.socket(AF_INET, Int32(SOCK_STREAM), 0)
#endif
        if fd < 0 {
            throw IOError(errno: errno, reason: "socket(...) failed")
        }
        super.init(descriptor: fd)
    }
    
    public func listen(backlog: Int32) throws {
#if os(Linux)
        let res = Glibc.listen(self.descriptor, backlog)
#else
        let res = Darwin.listen(self.descriptor, backlog)
#endif
        guard res >= 0 else {
            throw IOError(errno: errno, reason: "listen(...) failed")
        }
    }
    
    public func accept() throws -> Socket? {
        var acceptAddr = sockaddr_in()
        var addrSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        
#if os(Linux)
        let fd = withUnsafeMutablePointer(to: &acceptAddr) {
            Glibc.accept(self.descriptor, UnsafeMutableRawPointer($0).assumingMemoryBound(to: sockaddr.self), &addrSize)
        }
#else
        let fd = withUnsafeMutablePointer(to: &acceptAddr) {
            Darwin.accept(self.descriptor, UnsafeMutableRawPointer($0).assumingMemoryBound(to: sockaddr.self), &addrSize)
        }
#endif
        
        guard fd >= 0 else {
            let err = errno
            guard err == EWOULDBLOCK else {
                throw IOError(errno: errno, reason: "accept(...) failed")
            }
            return nil
        }
        return Socket(descriptor: fd)
    }
}
