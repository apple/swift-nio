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
let write0 = Darwin.write
let read0 = Darwin.read
let close0 = Darwin.close
let shutdown0 = Darwin.shutdown
    
#elseif os(Linux)
    import Glibc
let write0 = Glibc.write
let read0 = Glibc.read
let close0 = Glibc.close
let shutdown0 = Glibc.shutdown
#endif


public class Socket {
    public let fd: Int32;
    public internal(set) var open: Bool;
    
    init() throws {
        #if os(Linux)
            self.fd = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
            self.fd = Darwin.socket(AF_INET, Int32(SOCK_STREAM), 0)
        #endif
        if self.fd < 0 {
            throw IOError(errno: errno, reason: "socket(...) failed")
        }
        self.open = true
    }
    
    init(fd : Int32) {
        self.fd = fd
        self.open = true
    }
    
    public func localAddress() -> SocketAddress? {
        return nil
    }
    
    public func remoteAddress() -> SocketAddress? {
        return nil;
    }
    
    public func setNonBlocking() throws {
        let res = fcntl(self.fd, F_SETFL, O_NONBLOCK)
        
        guard res >= 0 else {
            let _ = close0(self.fd)
            throw IOError(errno: errno, reason: "fcntl(...) failed")
        }
        
    }
    
    public func close() throws {
        let res = close0(self.fd)
        
        guard res >= 0 else {
            throw IOError(errno: errno, reason: "shutdown(...) failed")
        }
    }
    
    public func write(data: [UInt8], offset: UInt32, len: UInt32) throws -> UInt32 {
        let res = write0(self.fd, UnsafeMutablePointer(mutating: data).advanced(by: Int(offset)), Int(len))
        
        guard res >= 0 else {
            throw IOError(errno: errno, reason: "write(...) failed")
        }
        return UInt32(res)
    }
    
    public func read(data: inout [UInt8], offset: UInt32, len: UInt32) throws -> UInt32 {
        let res = read0(self.fd, UnsafeMutablePointer(mutating: data).advanced(by: Int(offset)), Int(len))
        guard res >= 0 else {
            throw IOError(errno: errno, reason: "read(...) failed")
        }
        return UInt32(res)
    }
}
