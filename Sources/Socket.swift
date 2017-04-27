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
#else
import Darwin
#endif


public class Socket : Selectable {
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
    
    init() throws {
#if os(Linux)
        self.descriptor = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
#else
        self.descriptor = Darwin.socket(AF_INET, Int32(SOCK_STREAM), 0)
#endif
        if self.descriptor < 0 {
            throw IOError(errno: errno, reason: "socket(...) failed")
        }
        self.open = true
    }
    
    init(descriptor : Int32) {
        self.descriptor = descriptor
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
            throw IOError(errno: errno, reason: "shutdown(...) failed")
        }
        self.open = false
    }
    
    public func write(data: Data, offset: Int, len: Int) throws -> Int {
        let res = data.withUnsafeBytes() { [unowned self] (buffer: UnsafePointer<UInt8>) -> Int in
        #if os(Linux)
            return Glibc.write(self.descriptor, buffer.advanced(by: offset), len)
        #else
            return Darwin.Glibc.write(self.descriptor, buffer.advanced(by: offset), len)
        #endif
        }

        guard res >= 0 else {
            let err = errno
            guard err == EWOULDBLOCK else {
                throw IOError(errno: errno, reason: "write(...) failed")
            }
            return -1
        }
        return res
    }
    
    public func read(data: inout Data, offset: Int, len: Int) throws -> Int {
        let res = data.withUnsafeMutableBytes() { [unowned self] (buffer: UnsafeMutablePointer<UInt8>) -> Int in
            #if os(Linux)
                return Glibc.read(self.descriptor, buffer.advanced(by: offset), len)
            #else
                return Darwin.read(self.descriptor, buffer.advanced(by: offset), len)
            #endif
        }

        guard res >= 0 else {
            let err = errno
            guard err == EWOULDBLOCK else {
                throw IOError(errno: errno, reason: "read(...) failed")
            }
            return -1
        }
        return res
    }
}
