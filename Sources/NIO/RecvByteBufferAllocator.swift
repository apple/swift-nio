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

/// Allocates `ByteBuffer`s to be used to read bytes from a `Channel` and records the number of the actual bytes that were used.
public protocol RecvByteBufferAllocator {
    /// Allocates a new `ByteBuffer` that will be used to read bytes from a `Channel`.
    func buffer(allocator: ByteBufferAllocator) -> ByteBuffer

    /// Records the actual number of bytes that were read by the last socket call.
    ///
    /// - parameters:
    ///     - actualReadBytes: The number of bytes that were used by the previous allocated `ByteBuffer`
    /// - returns: `true` if the next call to `buffer` may return a bigger buffer then the last call to `buffer`.
    mutating func record(actualReadBytes: Int) -> Bool
}



/// `RecvByteBufferAllocator` which will always return a `ByteBuffer` with the same fixed size no matter what was recorded.
public struct FixedSizeRecvByteBufferAllocator: RecvByteBufferAllocator {
    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public mutating func record(actualReadBytes: Int) -> Bool {
        // Returns false as we always allocate the same size of buffers.
        return false
    }

    public func buffer(allocator: ByteBufferAllocator) -> ByteBuffer {
        return allocator.buffer(capacity: capacity)
    }
}

/// `RecvByteBufferAllocator` which will gracefully increment or decrement the buffer size on the feedback that was recorded.
public struct AdaptiveRecvByteBufferAllocator: RecvByteBufferAllocator {

    private static let indexIncrement = 4
    private static let indexDecrement = 1

    private static let sizeTable: [Int] = {
        var sizeTable: [Int] = []

        var i: Int = 16
        while i < 512 {
            sizeTable.append(i)
            i += 16
        }

        i = 512
        while i < UInt32.max { // 1 << 32 max buffer size
            sizeTable.append(i)
            i <<= 1
        }

        return sizeTable
    }()

    private let minIndex: Int
    private let maxIndex: Int
    public let minimum: Int
    public let maximum: Int
    public let initial: Int

    private var index: Int
    private var nextReceiveBufferSize: Int
    private var decreaseNow: Bool

    public init() {
        self.init(minimum: 64, initial: 2048, maximum: 65536)
    }

    public init(minimum: Int, initial: Int, maximum: Int) {
        precondition(minimum >= 0, "minimum: \(minimum)")
        precondition(initial > minimum, "initial: \(initial)")
        precondition(maximum > initial, "maximum: \(maximum)")

        let minIndex = AdaptiveRecvByteBufferAllocator.sizeTableIndex(minimum)
        if AdaptiveRecvByteBufferAllocator.sizeTable[minIndex] < minimum {
            self.minIndex = minIndex + 1
        } else {
            self.minIndex = minIndex
        }

        let maxIndex = AdaptiveRecvByteBufferAllocator.sizeTableIndex(maximum)
        if AdaptiveRecvByteBufferAllocator.sizeTable[maxIndex] > maximum {
            self.maxIndex = maxIndex - 1
        } else {
            self.maxIndex = maxIndex
        }

        self.initial = initial
        self.minimum = minimum
        self.maximum = maximum

        self.index = AdaptiveRecvByteBufferAllocator.sizeTableIndex(initial)
        self.nextReceiveBufferSize = AdaptiveRecvByteBufferAllocator.sizeTable[index]
        self.decreaseNow = false
    }

    private static func sizeTableIndex(_ size: Int) -> Int {
        var low: Int = 0
        var high: Int = sizeTable.count - 1

        repeat {
            if high < low {
                return low
            }
            if high == low {
                return high
            }

            // It's important to put (...) around as >> is executed before + in Swift while in Java it's the other way around (doh!)
            let mid = (low + high) >> 1

            let a = sizeTable[mid]
            let b = sizeTable[mid + 1]

            if size > b {
                low = mid + 1
            } else if size < a {
                high = mid - 1
            } else if size == a {
                return mid
            } else {
                return mid + 1
            }
        } while true
    }

    public func buffer(allocator: ByteBufferAllocator) -> ByteBuffer {
        return allocator.buffer(capacity: nextReceiveBufferSize)
    }

    public mutating func record(actualReadBytes: Int) -> Bool {
        if actualReadBytes <= AdaptiveRecvByteBufferAllocator.sizeTable[max(0, index - AdaptiveRecvByteBufferAllocator.indexDecrement - 1)] {
            if decreaseNow {
                index = max(index - AdaptiveRecvByteBufferAllocator.indexDecrement, minIndex)
                nextReceiveBufferSize = AdaptiveRecvByteBufferAllocator.sizeTable[index]
                decreaseNow = false
            } else {
                decreaseNow = true
            }
        } else if actualReadBytes >= nextReceiveBufferSize {
            index = min(index + AdaptiveRecvByteBufferAllocator.indexIncrement, maxIndex)
            nextReceiveBufferSize = AdaptiveRecvByteBufferAllocator.sizeTable[index]
            decreaseNow = false

        }
        return actualReadBytes >= nextReceiveBufferSize
    }
}
