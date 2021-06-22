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

/// Used to write a conforming type into a `ByteBuffer` so that it can be used in a result builder.
public protocol ByteBufferSerializable {
    
    @discardableResult func write(into buffer: inout ByteBuffer) -> Int
    
}

extension String: ByteBufferSerializable {
    
    /// Writes `self` into a `ByteBuffer`.
    /// - parameter buffer: The target `ByteBuffer`.
    /// - returns: The number of bytes written.
    public func write(into buffer: inout ByteBuffer) -> Int {
        return buffer.writeString(self)
    }
    
}

extension Substring: ByteBufferSerializable {
    
    /// Writes `self` into a `ByteBuffer`.
    /// - parameter buffer: The target `ByteBuffer`.
    /// - returns: The number of bytes written.
    public func write(into buffer: inout ByteBuffer) -> Int {
        return buffer.writeSubstring(self)
    }
    
}

extension StaticString: ByteBufferSerializable {
    
    /// Writes `self` into a `ByteBuffer`.
    /// - parameter buffer: The target `ByteBuffer`.
    /// - returns: The number of bytes written.
    public func write(into buffer: inout ByteBuffer) -> Int {
        return buffer.writeStaticString(self)
    }
    
}

extension Sequence where Element == UInt8 {
    
    /// Writes `self` into a `ByteBuffer`.
    /// - parameter buffer: The target `ByteBuffer`.
    /// - returns: The number of bytes written.
    public func write(into buffer: inout ByteBuffer) -> Int {
        return buffer.writeBytes(self)
    }
    
}

extension FixedWidthInteger where Self: ByteBufferSerializable {
    
    /// Writes `self` into a `ByteBuffer`.
    /// - parameter buffer: The target `ByteBuffer`.
    /// - returns: The number of bytes written.
    public func write(into buffer: inout ByteBuffer) -> Int {
        return buffer.writeInteger(self)
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

#if compiler(>=5.4)

@resultBuilder
public struct BufferBuilder {
    public static func buildBlock(_ components: ByteBufferSerializable...) -> [ByteBufferSerializable] {
        return components
    }
}

extension ByteBuffer {
 
    /// Creates a new `ByteBuffer` using a result builder.
    /// - parameter contents: A result builder that uses `ByteBufferSerializable` types.
    public init(@BufferBuilder contents: () -> [ByteBufferSerializable]) {
        self.init()
        for part in contents() {
            part.write(into: &self)
        }
    }
    
    /// Writes to `self` using a resut builder.
    /// - parameter contents: A result builder that uses `ByteBufferSerializable` types.
    /// - returns: The number of bytes written.
    public mutating func write(@BufferBuilder contents: () -> [ByteBufferSerializable]) -> Int {
        return contents().map { $0.write(into: &self) }.reduce(0, +)
    }
    
}

#endif
