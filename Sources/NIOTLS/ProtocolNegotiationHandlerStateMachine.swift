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

import DequeModule
import NIOCore

struct ProtocolNegotiationHandlerStateMachine<NegotiationResult> {
    enum State {
        /// The state before we received a TLSUserEvent. We are just forwarding any read at this point.
        case initial
        /// The state after we received a ``TLSUserEvent`` and are waiting for the future of the user to complete.
        case waitingForUser(buffer: Deque<NIOAny>)
        /// The state after the users future finished and we are unbuffering all the reads.
        case unbuffering(buffer: Deque<NIOAny>)
        /// The state once the negotiation is done and we are finished with unbuffering.
        case finished
    }

    private var state = State.initial

    @usableFromInline
    enum HandlerRemovedAction {
        case failPromise
    }

    @inlinable
    mutating func handlerRemoved() -> HandlerRemovedAction? {
        switch self.state {
        case .initial, .waitingForUser, .unbuffering:
            return .failPromise

        case .finished:
            return .none
        }
    }

    @usableFromInline
    enum UserInboundEventTriggeredAction {
        case fireUserInboundEventTriggered
        case invokeUserClosure(ALPNResult)
    }

    @inlinable
    mutating func userInboundEventTriggered(event: Any) -> UserInboundEventTriggeredAction {
        if case .handshakeCompleted(let negotiated) = event as? TLSUserEvent {
            switch self.state {
            case .initial:
                self.state = .waitingForUser(buffer: .init())

                return .invokeUserClosure(.init(negotiated: negotiated))
            case .waitingForUser, .unbuffering:
                preconditionFailure("Unexpectedly received two TLSUserEvents")

            case .finished:
                // This is weird but we can tolerate it and just forward the event
                return .fireUserInboundEventTriggered
            }
        } else {
            return .fireUserInboundEventTriggered
        }
    }

    @usableFromInline
    enum ChannelReadAction {
        case fireChannelRead
    }

    @inlinable
    mutating func channelRead(data: NIOAny) -> ChannelReadAction? {
        switch self.state {
        case .initial, .finished:
            return .fireChannelRead

        case .waitingForUser(var buffer):
            buffer.append(data)
            self.state = .waitingForUser(buffer: buffer)

            return .none

        case .unbuffering(var buffer):
            buffer.append(data)
            self.state = .unbuffering(buffer: buffer)

            return .none
        }
    }

    @usableFromInline
    enum UserFutureCompletedAction {
        case fireErrorCaughtAndRemoveHandler(Error)
        case fireErrorCaughtAndStartUnbuffering(Error)
        case startUnbuffering(NegotiationResult)
        case removeHandler(NegotiationResult)
    }

    @inlinable
    mutating func userFutureCompleted(with result: Result<NegotiationResult, Error>) -> UserFutureCompletedAction? {
        switch self.state {
        case .initial:
            preconditionFailure("Invalid state \(self.state)")

        case .waitingForUser(let buffer):

            switch result {
            case .success(let value):
                if !buffer.isEmpty {
                    self.state = .unbuffering(buffer: buffer)
                    return .startUnbuffering(value)
                } else {
                    self.state = .finished
                    return .removeHandler(value)
                }

            case .failure(let error):
                if !buffer.isEmpty {
                    self.state = .unbuffering(buffer: buffer)
                    return .fireErrorCaughtAndStartUnbuffering(error)
                } else {
                    self.state = .finished
                    return .fireErrorCaughtAndRemoveHandler(error)
                }
            }

        case .unbuffering:
            preconditionFailure("Invalid state \(self.state)")

        case .finished:
            // It might be that the user closed the channel in his closure. We have to tolerate this.
            return .none
        }
    }

    @usableFromInline
    enum UnbufferAction {
        case fireChannelRead(NIOAny)
        case fireChannelReadCompleteAndRemoveHandler
    }

    @inlinable
    mutating func unbuffer() -> UnbufferAction {
        switch self.state {
        case .initial, .waitingForUser, .finished:
            preconditionFailure("Invalid state \(self.state)")

        case .unbuffering(var buffer):
            if let element = buffer.popFirst() {
                self.state = .unbuffering(buffer: buffer)

                return .fireChannelRead(element)
            } else {
                self.state = .finished

                return .fireChannelReadCompleteAndRemoveHandler
            }
        }
    }

    @inlinable
    mutating func channelInactive() {
        switch self.state {
        case .initial, .unbuffering, .waitingForUser:
            self.state = .finished

        case .finished:
            break
        }
    }
}
