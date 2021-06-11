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
    public let minimum: Int
    public let maximum: Int
    public let initial: Int

    private var nextReceiveBufferSize: Int
    private var decreaseNow: Bool

    private static let maximumAllocationSize = 1 << 30

    public init() {
        self.init(minimum: 64, initial: 2048, maximum: 65536)
    }

    public init(minimum: Int, initial: Int, maximum: Int) {
        precondition(minimum >= 0, "minimum: \(minimum)")
        precondition(initial >= minimum, "initial: \(initial)")
        precondition(maximum >= initial, "maximum: \(maximum)")

        // We need to round all of these numbers to a power of 2. Initial will be rounded down,
        // minimum down, and maximum up.
        self.minimum = min(minimum, AdaptiveRecvByteBufferAllocator.maximumAllocationSize).previousPowerOf2()
        self.initial = min(initial, AdaptiveRecvByteBufferAllocator.maximumAllocationSize).previousPowerOf2()
        self.maximum = min(maximum, AdaptiveRecvByteBufferAllocator.maximumAllocationSize).nextPowerOf2()

        self.nextReceiveBufferSize = self.initial
        self.decreaseNow = false
    }

    public func buffer(allocator: ByteBufferAllocator) -> ByteBuffer {
        return allocator.buffer(capacity: self.nextReceiveBufferSize)
    }

    public mutating func record(actualReadBytes: Int) -> Bool {
        precondition(self.nextReceiveBufferSize % 2 == 0)
        precondition(self.nextReceiveBufferSize >= self.minimum)
        precondition(self.nextReceiveBufferSize <= self.maximum)

        var mayGrow = false

        // This right shift is safe: nextReceiveBufferSize can never be negative, so this will stop at 0.
        let lowerBound = self.nextReceiveBufferSize &>> 1

        // Here we need to be careful with 32-bit systems: if maximum is too large then any shift or multiply will overflow, which
        // we don't want. Instead we check, and clamp to this current value if we overflow.
        let upperBoundCandidate = Int(truncatingIfNeeded: Int64(self.nextReceiveBufferSize) &<< 1)
        let upperBound = upperBoundCandidate <= 0 ? self.nextReceiveBufferSize : upperBoundCandidate

        if actualReadBytes <= lowerBound && lowerBound >= self.minimum {
            if self.decreaseNow {
                self.nextReceiveBufferSize = lowerBound
                self.decreaseNow = false
            } else {
                self.decreaseNow = true
            }
        } else if actualReadBytes >= self.nextReceiveBufferSize && upperBound <= self.maximum &&
                  self.nextReceiveBufferSize != upperBound {
            self.nextReceiveBufferSize = upperBound
            self.decreaseNow = false
            mayGrow = true
        } else {
            self.decreaseNow = false
        }

        return mayGrow
    }
}
