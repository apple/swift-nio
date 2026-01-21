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

import NIOCore

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
private typealias SequenceProducer = NIOAsyncSequenceProducer<
    Int, NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark, Delegate
>

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
private final class Delegate: NIOAsyncSequenceProducerDelegate, @unchecked Sendable {
    private let elements = Array(repeating: 1, count: 1000)

    var source: SequenceProducer.Source!

    func produceMore() {
        _ = self.source.yield(contentsOf: self.elements)
    }

    func didTerminate() {}
}

func run(identifier: String) {
    guard #available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *) else {
        return
    }
    measure(identifier: identifier) {
        let delegate = Delegate()
        let producer = SequenceProducer.makeSequence(
            backPressureStrategy: .init(lowWatermark: 100, highWatermark: 500),
            delegate: delegate
        )
        let sequence = producer.sequence
        delegate.source = producer.source

        var counter = 0
        for await i in sequence {
            counter += i

            if counter == 10_000_000 {
                return counter
            }
        }

        return counter
    }
}
