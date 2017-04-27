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


public class ServerSocket: Selectable {
    public let descriptor: Int32;
    public private(set) var open: Bool;
   
    public var localAddress: SocketAddress? {
        get {
            return nil
        }
    }
    public var remoteAddress: SocketAddress? {
        get {
            return nil
        }
    }
    
    public class func bootstrap(host: String, port: Int32) throws -> ServerSocket {
        let socket = try ServerSocket();
        try socket.bind(address: SocketAddresses.newAddress(for: host, on: port)!)
        try socket.listen(backlog: 128)
        return socket
    }
    
    init() throws {
#if os(Linux)
        self.descriptor = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
#else
        self.descriptor = Darwin.socket(AF_INET, Int32(SOCK_STREAM), 0)
#endif
        guard self.descriptor >= 0 else {
            throw IOError(errno: errno, reason: "socket(...) failed")
        }
        self.open = true
    }
    
    public func setNonBlocking() throws {
        let res = fcntl(self.descriptor, F_SETFL, O_NONBLOCK)
        
        guard res >= 0 else {
            throw IOError(errno: errno, reason: "fcntl(...) failed")
        }
        
    }
    
    public func close() throws {
#if os(Linux)
        let res = Glibc.close(self.descriptor)
#else
        let res = Darwin.close(self.descriptor)
#endif
        
        guard res >= 0 else {
            throw IOError(errno: errno, reason: "close(...) failed")
        }
        self.open = false
    }
    
    public func bind(address: SocketAddress) throws {
        var addr = address.addr
        
#if os(Linux)
        let res = withUnsafePointer(to: &addr) {
            Glibc.bind(self.descriptor, UnsafePointer<sockaddr>($0), socklen_t(address.size));
        }
#else
        let res = withUnsafePointer(to: &addr) {
            Darwin.bind(self.descriptor, UnsafePointer<sockaddr>($0), socklen_t(address.size));
        }
#endif
        
        guard res >= 0 else {
            throw IOError(errno: errno, reason: "bind(...) failed")
        }
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
            Darwin.accept(self.fd, UnsafeMutableRawPointer($0).assumingMemoryBound(to: sockaddr.self), &addrSize)
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
