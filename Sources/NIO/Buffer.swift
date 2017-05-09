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

public class Buffer {
    var data: Data
    var offset: Int
    var limit: Int
    
    init(capacity: Int32) {
        self.data = Data(repeating: 0, count: Int(capacity))
        self.offset = 0
        self.limit = 0;
    }
    
    public func clear() {
        self.offset = 0
        self.limit = 0
    }
}

public protocol BufferAllocator {
    
    func buffer(capacity: Int32) -> Buffer
    
    func buffer() -> Buffer
}

extension BufferAllocator {
    public func buffer() -> Buffer {
        return buffer(capacity: 256)
    }
}

public class DefaultBufferAllocator : BufferAllocator {
    public init() {}
    
    public func buffer(capacity: Int32) -> Buffer {
        return Buffer(capacity: capacity)
    }
}
