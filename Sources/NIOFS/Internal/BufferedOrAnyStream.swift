//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

/// Wraps a ``NIOThrowingAsyncSequenceProducer<Element>`` or ``AnyAsyncSequence<Element>``.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
internal enum BufferedOrAnyStream<Element: Sendable, Delegate: NIOAsyncSequenceProducerDelegate>: Sendable {
    typealias AsyncSequenceProducer = NIOThrowingAsyncSequenceProducer<
        Element, Error, NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark, Delegate
    >

    case nioThrowingAsyncSequenceProducer(AsyncSequenceProducer)
    case anyAsyncSequence(AnyAsyncSequence<Element>)

    internal init(wrapping stream: AsyncSequenceProducer) {
        self = .nioThrowingAsyncSequenceProducer(stream)
    }

    internal init<S: AsyncSequence & Sendable>(wrapping stream: S)
    where S.Element == Element, S.AsyncIterator: NIOFileSystemSendableMetatype {
        self = .anyAsyncSequence(AnyAsyncSequence(wrapping: stream))
    }

    internal func makeAsyncIterator() -> AsyncIterator {
        switch self {
        case let .nioThrowingAsyncSequenceProducer(stream):
            return AsyncIterator(wrapping: stream.makeAsyncIterator())
        case let .anyAsyncSequence(stream):
            return AsyncIterator(wrapping: stream.makeAsyncIterator())
        }
    }

    internal enum AsyncIterator: AsyncIteratorProtocol {
        case bufferedStream(AsyncSequenceProducer.AsyncIterator)
        case anyAsyncSequence(AnyAsyncSequence<Element>.AsyncIterator)

        internal mutating func next() async throws -> Element? {
            let element: Element?
            switch self {
            case let .bufferedStream(iterator):
                defer { self = .bufferedStream(iterator) }
                element = try await iterator.next()
            case var .anyAsyncSequence(iterator):
                defer { self = .anyAsyncSequence(iterator) }
                element = try await iterator.next()
            }
            return element
        }

        internal init(wrapping iterator: AsyncSequenceProducer.AsyncIterator) {
            self = .bufferedStream(iterator)
        }

        internal init(wrapping iterator: AnyAsyncSequence<Element>.AsyncIterator) {
            self = .anyAsyncSequence(iterator)
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
internal struct AnyAsyncSequence<Element>: AsyncSequence, Sendable {
    private let _makeAsyncIterator: @Sendable () -> AsyncIterator

    internal init<S: AsyncSequence & Sendable>(wrapping sequence: S)
    where S.Element == Element, S.AsyncIterator: NIOFileSystemSendableMetatype {
        self._makeAsyncIterator = {
            AsyncIterator(wrapping: sequence.makeAsyncIterator())
        }
    }

    internal func makeAsyncIterator() -> AsyncIterator {
        self._makeAsyncIterator()
    }

    internal struct AsyncIterator: AsyncIteratorProtocol, NIOFileSystemSendableMetatype {
        private var iterator: any AsyncIteratorProtocol

        init<I: AsyncIteratorProtocol>(wrapping iterator: I) where I.Element == Element {
            self.iterator = iterator
        }

        internal mutating func next() async throws -> Element? {
            try await self.iterator.next() as? Element
        }
    }
}
