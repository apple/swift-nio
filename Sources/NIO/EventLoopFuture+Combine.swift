//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if canImport(Combine)
import Combine


// MARK:- Obtain a publisher from an EventLoopFuture
@available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension EventLoopFuture {
    /// Obtain a Combine `Publisher` for this `EventLoopFuture`.
    @inlinable
    public var publisher: EventLoopFuture.Publisher {
        return Publisher(self)
    }
}


// MARK:- Definition of EventLoopFuture.Publisher
@available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension EventLoopFuture {
    /// A `Publisher` that publishes the results of an `EventLoopFuture`.
    ///
    /// An `EventLoopFuture.Publisher` is a Combine `Publisher` that will
    /// publish exactly once, either a value or an error. This publication will
    /// occur when the `EventLoopFuture` to which it corresponds completes.
    public struct Publisher {
        /// The `EventLoopFuture` whose result this `Publisher` publishes.
        @usableFromInline
        internal var future: EventLoopFuture<Value>

        @inlinable
        internal init(_ future: EventLoopFuture<Value>) {
            self.future = future
        }
    }
}


// MARK:- Definition of EventLoopFuture.Publisher.Subscription
@available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension EventLoopFuture.Publisher {
    /// A `Subscription` to an `EventLoopFuture.Publisher`.
    ///
    /// This object manages actually attaching the callback to the future at the point where
    /// data is demanded.
    @usableFromInline
    internal class Subscription<S: Subscriber> where Failure == S.Failure, Output == S.Input {
        /// The `EventLoopFuture` that the subscriber is subscribing to the result of.
        @usableFromInline
        internal var future: EventLoopFuture<Value>

        /// The subscriber that subscribed to this future.
        @usableFromInline
        internal var subscriber: S?

        @inlinable
        init(future: EventLoopFuture<Value>, subscriber: S) {
            self.future = future
            self.subscriber = subscriber
        }
    }
}


// MARK:- Publisher conformance
@available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension EventLoopFuture.Publisher: Publisher {
    public typealias Output = Value
    public typealias Failure = Error

    @inlinable
    public func receive<S>(subscriber: S) where S : Subscriber, Failure == S.Failure, Output == S.Input {
        subscriber.receive(subscription: EventLoopFuture.Publisher.Subscription(future: self.future, subscriber: subscriber))
    }
}


// MARK:- Subscription conformance
@available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension EventLoopFuture.Publisher.Subscription: Subscription {
    @inlinable
    func request(_ demand: Subscribers.Demand) {
        // This is unlikely, but double check that this is actually for non-zero demand.
        if case .max(let limit) = demand, limit <= 0 {
            return
        }

        self.future.whenComplete { result in
            // If the subscriber went away while we were waiting for a result,
            // ignore this.
            guard let subscriber = self.subscriber else {
                return
            }

            // Prevent further result delivery from this point.
            self.subscriber = nil

            switch result {
            case .success(let output):
                // We ignore extra demand.
                _ = subscriber.receive(output)
                subscriber.receive(completion: .finished)
            case .failure(let error):
                subscriber.receive(completion: .failure(error))
            }
        }
    }

    @inlinable
    func cancel() {
        self.future.eventLoop.execute {
            self.subscriber = nil
        }
    }

    @inlinable
    var combineIdentifier: CombineIdentifier {
        return CombineIdentifier(self)
    }
}

#endif
