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

import Dispatch

// MARK: - Serializable

public protocol ByteBufferSerializable {
    
    @discardableResult func write(into buffer: inout ByteBuffer) -> Int
    
}

extension String: ByteBufferSerializable {
    
    public func write(into buffer: inout ByteBuffer) -> Int {
        buffer.writeString(self)
    }
    
}

extension Substring: ByteBufferSerializable {
    
    public func write(into buffer: inout ByteBuffer) -> Int {
        buffer.writeSubstring(self)
    }
    
}

extension StaticString: ByteBufferSerializable {
    
    public func write(into buffer: inout ByteBuffer) -> Int {
        buffer.writeStaticString(self)
    }
    
}

extension Sequence where Element == UInt8 {
    
    public func write(into buffer: inout ByteBuffer) -> Int {
        buffer.writeBytes(self)
    }
    
}

extension FixedWidthInteger where Self: ByteBufferSerializable {
    
    public func write(into buffer: inout ByteBuffer) -> Int {
        buffer.writeInteger(self)
    }
    
}

extension Int: ByteBufferSerializable {}
extension Int8: ByteBufferSerializable {}
extension Int16: ByteBufferSerializable {}
extension Int32: ByteBufferSerializable {}
extension Int64: ByteBufferSerializable {}
extension UInt: ByteBufferSerializable {}
extension UInt8: ByteBufferSerializable {}
extension UInt16: ByteBufferSerializable {}
extension UInt32: ByteBufferSerializable {}
extension UInt64: ByteBufferSerializable {}

// MARK: - Buffer builder

@resultBuilder
public struct BufferBuilder {
    public static func buildBlock(_ components: ByteBufferSerializable...) -> [ByteBufferSerializable] {
        components
    }
}

extension ByteBuffer {
 
    init(@BufferBuilder contents: () -> [ByteBufferSerializable]) {
        self.init()
        for part in contents() {
            part.write(into: &self)
        }
    }
    
    public mutating func write(@BufferBuilder contents: () -> [ByteBufferSerializable]) -> Int {
        contents().map { $0.write(into: &self) }.reduce(0, +)
    }
    
}
