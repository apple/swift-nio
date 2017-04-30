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


// TODO: Add gathering / scattering support
public class Socket : BaseSocket {
    
    public func write(data: Data) throws -> UInt? {
        return try write(data: data, offset: 0, len: data.count)
    }

    public func write(data: Data, offset: Int, len: Int) throws -> UInt? {
        while true {
            let res = data.withUnsafeBytes() { [unowned self] (buffer: UnsafePointer<UInt8>) -> Int in
                #if os(Linux)
                    return Glibc.write(self.descriptor, buffer.advanced(by: offset), len)
                #else
                    return Darwin.write(self.descriptor, buffer.advanced(by: offset), len)
                #endif
            }

            guard res >= 0 else {
                let err = errno
                if err == EINTR {
                    continue
                }
                guard err == EWOULDBLOCK else {
                    throw IOError(errno: errno, reason: "write(...) failed")
                }
                return nil
            }
            return UInt(res)
        }
    }
    
    public func read(data: inout Data) throws -> UInt? {
        return try read(data: &data, offset: 0, len: data.count)
    }

    public func read(data: inout Data, offset: Int, len: Int) throws -> UInt? {
        while true {
            let res = data.withUnsafeMutableBytes() { [unowned self] (buffer: UnsafeMutablePointer<UInt8>) -> Int in
                #if os(Linux)
                    return Glibc.read(self.descriptor, buffer.advanced(by: offset), len)
                #else
                    return Darwin.read(self.descriptor, buffer.advanced(by: offset), len)
                #endif
            }
            
            guard res >= 0 else {
                let err = errno
                if err == EINTR {
                    continue
                }
                guard err == EWOULDBLOCK else {
                    throw IOError(errno: errno, reason: "read(...) failed")
                }
                return nil
            }
            return UInt(res)
        }
    }
}
