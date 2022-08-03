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

#if compiler(>=5.5.2) && canImport(_Concurrency)
/// A high-low watermarked back-pressure strategy for a ``NIOAsyncSequenceProducer``.
///
/// This strategy does the following:
/// - On yield it keeps on demanding more as long as the `highWatermark` isn't reached.
/// - On next it starts to demand once the the `lowWatermark` is reached.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncSequenceProducer {
    public struct HighLowWatermarkBackPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategy {
        private let lowWatermark: Int
        private let highWatermark: Int

        /// Initializes a new ``HighLowWatermarkBackPressureStrategy``.
        ///
        /// - Parameters:
        ///   - lowWatermark: The low watermark where demand should start.
        ///   - highWatermark: The high watermark where demand should be stopped.
        public init(lowWatermark: Int, highWatermark: Int) {
            self.lowWatermark = lowWatermark
            self.highWatermark = highWatermark
        }

        public mutating func didYield(bufferDepth: Int) -> Bool {
            // We are demanding more until we reach the high watermark
            bufferDepth < self.highWatermark
        }

        public mutating func didConsume(bufferDepth: Int) -> Bool {
            // We start demanding again once we are below the low watermark
            bufferDepth < self.lowWatermark
        }
    }
}
#endif
