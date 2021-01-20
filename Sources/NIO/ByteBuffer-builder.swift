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

public protocol ByteBufferSerializable {
    
    @discardableResult func write(into buffer: inout ByteBuffer) -> Int
    
}

extension String: ByteBufferSerializable {
    
    public func write(into buffer: inout ByteBuffer) -> Int {
        buffer.writeString(self)
    }
    
}

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
