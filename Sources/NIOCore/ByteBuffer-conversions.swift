//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Dispatch

extension Array where Element == UInt8 {
    
    /// Creates a `[UInt8]` from the given buffer. The entire readable portion of the buffer will be read.
    /// - parameter buffer: The buffer to read.
    @inlinable
    public init(buffer: ByteBuffer) {
        var buffer = buffer
        self = buffer.readBytes(length: buffer.readableBytes)!
    }
    
}

extension String {
    
    /// Creates a `String` from a given `ByteBuffer`. The entire readable portion of the buffer will be read.
    /// - parameter buffer: The buffer to read.
    @inlinable
    public init(buffer: ByteBuffer) {
        var buffer = buffer
        self = buffer.readString(length: buffer.readableBytes)!
    }
    
}

extension DispatchData {
    
    /// Creates a `DispatchData` from a given `ByteBuffer`. The entire readable portion of the buffer will be read.
    /// - parameter buffer: The buffer to read.
    @inlinable
    public init(buffer: ByteBuffer) {
        var buffer = buffer
        self = buffer.readDispatchData(length: buffer.readableBytes)!
    }
    
}
