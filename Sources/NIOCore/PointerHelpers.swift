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

// MARK: Rebasing shims

// FIXME: Duplicated in NIO.

// These methods are shimmed in to NIO until https://github.com/apple/swift/pull/34879 is resolved.
// They address the fact that the current rebasing initializers are surprisingly expensive and do excessive
// checked arithmetic. This expense forces them to often be outlined, reducing the ability to optimise out
// further preconditions and branches.
extension UnsafeRawBufferPointer {
    @inlinable
    init(fastRebase slice: Slice<UnsafeRawBufferPointer>) {
        let base = slice.base.baseAddress?.advanced(by: slice.startIndex)
        self.init(start: base, count: slice.endIndex &- slice.startIndex)
    }

    @inlinable
    init(fastRebase slice: Slice<UnsafeMutableRawBufferPointer>) {
        let base = slice.base.baseAddress?.advanced(by: slice.startIndex)
        self.init(start: base, count: slice.endIndex &- slice.startIndex)
    }
}

extension UnsafeMutableRawBufferPointer {
    @inlinable
    init(fastRebase slice: Slice<UnsafeMutableRawBufferPointer>) {
        let base = slice.base.baseAddress?.advanced(by: slice.startIndex)
        self.init(start: base, count: slice.endIndex &- slice.startIndex)
    }
}
