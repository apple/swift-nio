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

public enum NIOAsyncSequenceProducerBackPressureStrategies {
    /// A high-low watermarked back-pressure strategy for a ``NIOAsyncSequenceProducer``.
    ///
    /// This strategy does the following:
    /// - On yield it keeps on demanding more elements from the producer as long as the number of buffered elements hasn't reached the `highWatermark`.
    /// - On consume it starts to demand again from the producer once the number of buffered elements reach the `lowWatermark`.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public struct HighLowWatermark: NIOAsyncSequenceProducerBackPressureStrategy {
        private let lowWatermark: Int
        private let highWatermark: Int
        private var hasOustandingDemand: Bool = true

        /// Initializes a new ``NIOAsyncSequenceProducerBackPressureStrategies/HighLowWatermark``.
        ///
        /// - Parameters:
        ///   - lowWatermark: The low watermark where demand should start.
        ///   - highWatermark: The high watermark where demand should be stopped.
        public init(lowWatermark: Int, highWatermark: Int) {
            precondition(lowWatermark <= highWatermark)
            self.lowWatermark = lowWatermark
            self.highWatermark = highWatermark
        }

        public mutating func didYield(bufferDepth: Int) -> Bool {
            // We are demanding more until we reach the high watermark
            if bufferDepth < self.highWatermark {
                precondition(self.hasOustandingDemand)
                return true
            } else {
                self.hasOustandingDemand = false
                return false
            }
        }

        public mutating func didConsume(bufferDepth: Int) -> Bool {
            // We start demanding again once we are below the low watermark
            if bufferDepth < self.lowWatermark {
                if self.hasOustandingDemand {
                    // We are below and have outstanding demand
                    return true
                } else {
                    // We are below but don't have outstanding demand but need more
                    self.hasOustandingDemand = true
                    return true
                }
            } else {
                return self.hasOustandingDemand
            }
        }
    }
}
