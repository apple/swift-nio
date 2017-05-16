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
let sysWrite = Glibc.write
let sysRead = Glibc.read
#else
import Darwin
let sysWrite = Darwin.write
let sysRead = Darwin.read
#endif


// TODO: Add gathering / scattering support
public class Socket : BaseSocket {
    
    public func write(data: Data) throws -> Int? {
        return try write(data: data, offset: 0, len: data.count)
    }

    public func write( data: Data, offset: Int, len: Int) throws -> Int? {
        return try data.withUnsafeBytes({ try write(pointer: $0 + offset, size: len) })
    }

    public func write(pointer: UnsafePointer<UInt8>, size: Int) throws -> Int? {
        return try wrapSyscallMayBlock({ $0 >= 0 }, function: "write") {
            sysWrite(self.descriptor, pointer, size)
        }
    }

    public func read(data: inout Data) throws -> Int? {
        return try read(data: &data, offset: 0, len: data.count)
    }

    public func read(data: inout Data, offset: Int, len: Int) throws -> Int? {
        return try data.withUnsafeMutableBytes({ try read(pointer: $0 + offset, size: len) })
    }

    public func read(pointer: UnsafeMutablePointer<UInt8>, size: Int) throws -> Int? {
        return try wrapSyscallMayBlock({ $0 >= 0 }, function: "read") {
            sysRead(self.descriptor, pointer, size)
        }
    }
}
