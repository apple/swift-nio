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

/// An `Error` that represents multiple errors that occurred during an operation.
///
/// Because SwiftNIO frequently does multiple jobs at once, it is possible some operations out
/// of a set of operations may fail. This is most noticeable with `Channel.flush` on the
/// `DatagramChannel`, where some, but not all, of the datagram writes may fail. In this case
/// the `flush` should accurately represent that set of possibilities. The `NIOCompositeError`
/// is an attempt to do so.
public struct NIOCompositeError: Error {
    private let errors: [Error]

    public init(comprising errors: [Error]) {
        self.errors = errors
    }
}

extension NIOCompositeError: Sequence {
    public func makeIterator() -> Array<Error>.Iterator {
        return self.errors.makeIterator()
    }
}

extension NIOCompositeError: RandomAccessCollection {
    public typealias Element = Error
    public typealias Index = Array<Error>.Index
    public typealias Indices = Array<Error>.Indices
    public typealias SubSequence = Array<Error>.SubSequence

    public var endIndex: Index {
        return self.errors.endIndex
    }

    public var startIndex: Index {
        return self.errors.startIndex
    }

    public var indices: Indices {
        return self.errors.indices
    }

    public subscript(position: Index) -> Element {
        return self.errors[position]
    }

    public subscript(bounds: Range<Index>) -> SubSequence {
        return self.errors[bounds]
    }
}

extension NIOCompositeError: CustomStringConvertible {
    public var description: String {
        return "NIOCompositeError\(String(describing: self.errors))"
    }
}

extension NIOCompositeError: CustomDebugStringConvertible {
    public var debugDescription: String {
        return self.description
    }
}
