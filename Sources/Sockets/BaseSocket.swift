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

#if os(Linux)
    import Glibc
    let sysBind = Glibc.bind
    let sysClose = Glibc.close
    let sysSocket = Glibc.socket
    let sysSOCK_STREAM = SOCK_STREAM.rawValue
#else
    import Darwin
    let sysBind = Darwin.bind
    let sysClose = Darwin.close
    let sysSocket = Darwin.socket
    let sysSOCK_STREAM = SOCK_STREAM
#endif

public protocol Registration {
    var interested: IOEvent { get set }
}

public class BaseSocket : Selectable {
    public let descriptor: Int32
    public private(set) var open: Bool
    
    public final var localAddress: SocketAddress? {
        get {
            return nil
        }
    }
    public final var remoteAddress: SocketAddress? {
        get {
            return nil
        }
    }

    static func newSocket() throws -> Int32 {
        return try wrapSyscall({ $0 >= 0 }, function: "socket") { () -> Int32 in
            sysSocket(AF_INET, Int32(sysSOCK_STREAM), 0)
        }
    }
    
    // TODO: This needs a way to encourage proper open/close behavior.
    //       A closure a la Ruby's File.open may make sense.
    init(descriptor : Int32) {
        self.descriptor = descriptor
        self.open = true
    }

    public final func setNonBlocking() throws {
        guard self.open else {
            throw IOError(errno: EBADF, reason: "can't control file descriptor as it's not open anymore.")
        }

        let _ = try wrapSyscall({ $0 >= 0 }, function: "fcntl") {
            fcntl(self.descriptor, F_SETFL, O_NONBLOCK)
        }
    }
    
    public final func setOption<T>(level: Int32, name: Int32, value: T) throws {
        guard self.open else {
            throw IOError(errno: EBADF, reason: "can't set socket options as it's not open anymore.")
        }

        var val = value
        
        let _ = try wrapSyscall({ $0 != -1 }, function: "setsockopt") {
            setsockopt(
                self.descriptor,
                level,
                name,
                &val,
                socklen_t(MemoryLayout.size(ofValue: val)))
        }
    }

    public final func getOption<T>(level: Int32, name: Int32) throws -> T {
        guard self.open else {
            throw IOError(errno: EBADF, reason: "can't get socket options as it's not open anymore.")
        }

        var length = socklen_t(MemoryLayout<T>.size)
        var val = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer {
            val.deinitialize()
            val.deallocate(capacity: 1)
        }
        
        let _ = try wrapSyscall({ $0 != -1 }, function: "getsockopt") {
            getsockopt(self.descriptor, level, name, val, &length)
        }
        return val.pointee
    }
    
    public final func bind(to address: SocketAddress) throws {
        switch address {
        case .v4(address: let addr):
            try bindSocket(addr: addr)
        case .v6(address: let addr):
            try bindSocket(addr: addr)
        }
    }
    
    private func bindSocket<T>(addr: T) throws {
        guard self.open else {
            throw IOError(errno: EBADF, reason: "can't bind socket as it's not open anymore.")
        }

        var addr = addr
        try withUnsafePointer(to: &addr) { p in
            try p.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                _ = try wrapSyscall({ $0 != -1 }, function: "bind") {
                    sysBind(self.descriptor, ptr, socklen_t(MemoryLayout.size(ofValue: addr)))
                }
            }
        }
    }
    
    public final func close() throws {
        guard self.open else {
            throw IOError(errno: EBADF, reason: "can't close socket (as it's not open anymore.")
        }

        let _ = try wrapSyscall({ $0 >= 0 }, function: "close") {
             sysClose(self.descriptor)
        }
        self.open = false
    }
}
