//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

extension TimeAmount {
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    /// Creates a new `TimeAmount` for the given `Duration`, truncating and clamping if necessary.
    ///
    /// - Returns: `TimeAmount`, truncated to nanosecond precision, and clamped to `Int64.max` nanoseconds.
    public init(_ duration: Swift.Duration) {
        self = .nanoseconds(duration.nanosecondsClamped)
    }
}

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
extension Swift.Duration {
    /// Construct a `Duration` given a number of nanoseconds represented as a `TimeAmount`.
    public init(_ timeAmount: TimeAmount) {
        self = .nanoseconds(timeAmount.nanoseconds)
    }
}

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
extension Swift.Duration {
    /// The duration represented as nanoseconds, clamped to maximum expressible value.
    var nanosecondsClamped: Int64 {
        let components = self.components

        let secondsComponentNanos = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let attosCompononentNanos = components.attoseconds / 1_000_000_000
        let combinedNanos = secondsComponentNanos.partialValue.addingReportingOverflow(attosCompononentNanos)

        guard
            !secondsComponentNanos.overflow,
            !combinedNanos.overflow
        else {
            return .max
        }

        return combinedNanos.partialValue
    }
}
