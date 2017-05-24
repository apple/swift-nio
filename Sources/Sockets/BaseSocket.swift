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
#else
    import Darwin
    let sysBind = Darwin.bind
    let sysClose = Darwin.close
#endif


public class BaseSocket : Selectable {
    public let descriptor: Int32
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

    // TODO: This needs a way to encourage proper open/close behavior.
    //       A closure a la Ruby's File.open may make sense.
    init(descriptor : Int32) {
        self.descriptor = descriptor
        self.open = true
    }

    public func setNonBlocking() throws {
        let _ = try wrapSyscall({ $0 >= 0 }, function: "fcntl") {
            fcntl(self.descriptor, F_SETFL, O_NONBLOCK)
        }
    }
    
    public func setOption<T>(level: Int32, name: Int32, value: T) throws {
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
    
    public func getOption<T>(level: Int32, name: Int32) throws -> T {
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
    
    public func bind(local: SocketAddress) throws {
        switch local {
        case .v4(address: let addr):
            try bindSocket(addr: addr)
        case .v6(address: let addr):
            try bindSocket(addr: addr)
        }
    }
    
    private func bindSocket<T>(addr: T) throws {
        var addr = addr
        let _ = try withUnsafePointer(to: &addr) { (ptr: UnsafePointer<T>) -> Int32 in
            try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                try wrapSyscall({ $0 != -1 }, function: "bind") {
                    sysBind(self.descriptor, ptr, socklen_t(MemoryLayout.size(ofValue: addr)))
                }
            }
        }
    }
    
    public func close() throws {
        let _ = try wrapSyscall({ $0 >= 0 }, function: "close") {
             sysClose(self.descriptor)
        }
        self.open = false
    }
}
