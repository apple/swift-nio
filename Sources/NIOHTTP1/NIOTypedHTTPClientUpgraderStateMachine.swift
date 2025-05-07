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

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
struct NIOTypedHTTPClientUpgraderStateMachine<UpgradeResult> {
    @usableFromInline
    enum State {
        /// The state before we received a TLSUserEvent. We are just forwarding any read at this point.
        case initial(upgraders: [any NIOTypedHTTPClientProtocolUpgrader<UpgradeResult>])

        /// The request has been sent. We are waiting for the upgrade response.
        case awaitingUpgradeResponseHead(upgraders: [any NIOTypedHTTPClientProtocolUpgrader<UpgradeResult>])

        @usableFromInline
        struct AwaitingUpgradeResponseEnd {
            var upgrader: any NIOTypedHTTPClientProtocolUpgrader<UpgradeResult>
            var responseHead: HTTPResponseHead
        }
        /// We received the response head and are just waiting for the response end.
        case awaitingUpgradeResponseEnd(AwaitingUpgradeResponseEnd)

        @usableFromInline
        struct Upgrading {
            var buffer: Deque<NIOAny>
        }
        /// We are either running the upgrading handler.
        case upgrading(Upgrading)

        @usableFromInline
        struct Unbuffering {
            var buffer: Deque<NIOAny>
        }
        case unbuffering(Unbuffering)

        case finished

        case modifying
    }

    private var state: State

    init(upgraders: [any NIOTypedHTTPClientProtocolUpgrader<UpgradeResult>]) {
        self.state = .initial(upgraders: upgraders)
    }

    @usableFromInline
    enum HandlerRemovedAction {
        case failUpgradePromise
    }

    @inlinable
    mutating func handlerRemoved() -> HandlerRemovedAction? {
        switch self.state {
        case .initial, .awaitingUpgradeResponseHead, .awaitingUpgradeResponseEnd, .upgrading, .unbuffering:
            self.state = .finished
            return .failUpgradePromise

        case .finished:
            return .none

        case .modifying:
            fatalError("Internal inconsistency in HTTPClientUpgradeStateMachine")
        }
    }

    @usableFromInline
    enum ChannelActiveAction {
        case writeUpgradeRequest
    }

    @inlinable
    mutating func channelActive() -> ChannelActiveAction? {
        switch self.state {
        case .initial(let upgraders):
            self.state = .awaitingUpgradeResponseHead(upgraders: upgraders)
            return .writeUpgradeRequest

        case .finished:
            return nil

        case .awaitingUpgradeResponseHead, .awaitingUpgradeResponseEnd, .unbuffering, .upgrading:
            fatalError("Internal inconsistency in HTTPClientUpgradeStateMachine")

        case .modifying:
            fatalError("Internal inconsistency in HTTPClientUpgradeStateMachine")
        }
    }

    @usableFromInline
    enum WriteAction {
        case failWrite(Error)
        case forwardWrite
    }

    @usableFromInline
    func write() -> WriteAction {
        switch self.state {
        case .initial, .awaitingUpgradeResponseHead, .awaitingUpgradeResponseEnd, .upgrading:
            return .failWrite(NIOHTTPClientUpgradeError.writingToHandlerDuringUpgrade)

        case .unbuffering, .finished:
            return .forwardWrite

        case .modifying:
            fatalError("Internal inconsistency in HTTPClientUpgradeStateMachine")
        }
    }

    @usableFromInline
    enum ChannelReadDataAction {
        case unwrapData
        case fireChannelRead
    }

    @inlinable
    mutating func channelReadData(_ data: NIOAny) -> ChannelReadDataAction? {
        switch self.state {
        case .initial:
            return .unwrapData

        case .awaitingUpgradeResponseHead, .awaitingUpgradeResponseEnd:
            return .unwrapData

        case .upgrading(var upgrading):
            // We got a read while running upgrading.
            // We have to buffer the read to unbuffer it afterwards
            self.state = .modifying
            upgrading.buffer.append(data)
            self.state = .upgrading(upgrading)
            return nil

        case .unbuffering(var unbuffering):
            self.state = .modifying
            unbuffering.buffer.append(data)
            self.state = .unbuffering(unbuffering)
            return nil

        case .finished:
            return .fireChannelRead

        case .modifying:
            fatalError("Internal inconsistency in HTTPServerUpgradeStateMachine")
        }
    }

    @usableFromInline
    enum ChannelReadResponsePartAction {
        case fireErrorCaughtAndRemoveHandler(Error)
        case runNotUpgradingInitializer
        case startUpgrading(
            upgrader: any NIOTypedHTTPClientProtocolUpgrader<UpgradeResult>,
            responseHeaders: HTTPResponseHead
        )
    }

    @inlinable
    mutating func channelReadResponsePart(_ responsePart: HTTPClientResponsePart) -> ChannelReadResponsePartAction? {
        switch self.state {
        case .initial:
            fatalError("Internal inconsistency in HTTPClientUpgradeStateMachine")

        case .awaitingUpgradeResponseHead(let upgraders):
            // We should decide if we can upgrade based on the first response header: if we aren't upgrading,
            // by the time the body comes in we should be out of the pipeline. That means that if we don't think we're
            // upgrading, the only thing we should see is a response head. Anything else in an error.
            guard case .head(let response) = responsePart else {
                self.state = .finished
                return .fireErrorCaughtAndRemoveHandler(NIOHTTPClientUpgradeError.invalidHTTPOrdering)
            }

            // Assess whether the server has accepted our upgrade request.
            guard case .switchingProtocols = response.status else {
                var buffer = Deque<NIOAny>()
                buffer.append(.init(responsePart))
                self.state = .upgrading(.init(buffer: buffer))
                return .runNotUpgradingInitializer
            }

            // Ok, we have a HTTP response. Check if it's an upgrade confirmation.
            // If it's not, we want to pass it on and remove ourselves from the channel pipeline.
            let acceptedProtocols = response.headers[canonicalForm: "upgrade"]

            // At the moment we only upgrade to the first protocol returned from the server.
            guard let protocolName = acceptedProtocols.first?.lowercased() else {
                // There are no upgrade protocols returned.
                self.state = .finished
                return .fireErrorCaughtAndRemoveHandler(NIOHTTPClientUpgradeError.responseProtocolNotFound)
            }

            let matchingUpgrader =
                upgraders
                .first(where: { $0.supportedProtocol.lowercased() == protocolName })

            guard let upgrader = matchingUpgrader else {
                // There is no upgrader for this protocol.
                self.state = .finished
                return .fireErrorCaughtAndRemoveHandler(NIOHTTPClientUpgradeError.responseProtocolNotFound)
            }

            guard upgrader.shouldAllowUpgrade(upgradeResponse: response) else {
                // The upgrader says no.
                self.state = .finished
                return .fireErrorCaughtAndRemoveHandler(NIOHTTPClientUpgradeError.upgraderDeniedUpgrade)
            }

            // We received the response head and decided that we can upgrade.
            // We now need to wait for the response end and then we can perform the upgrade
            self.state = .awaitingUpgradeResponseEnd(
                .init(
                    upgrader: upgrader,
                    responseHead: response
                )
            )
            return .none

        case .awaitingUpgradeResponseEnd(let awaitingUpgradeResponseEnd):
            switch responsePart {
            case .head:
                // We got two HTTP response heads.
                self.state = .finished
                return .fireErrorCaughtAndRemoveHandler(NIOHTTPClientUpgradeError.invalidHTTPOrdering)

            case .body:
                // We tolerate body parts to be send but just ignore them
                return .none

            case .end:
                // We got the response end and can now run the upgrader.
                self.state = .upgrading(.init(buffer: .init()))
                return .startUpgrading(
                    upgrader: awaitingUpgradeResponseEnd.upgrader,
                    responseHeaders: awaitingUpgradeResponseEnd.responseHead
                )
            }

        case .upgrading, .unbuffering, .finished:
            fatalError("Internal inconsistency in HTTPClientUpgradeStateMachine")

        case .modifying:
            fatalError("Internal inconsistency in HTTPClientUpgradeStateMachine")
        }
    }

    @usableFromInline
    enum UpgradingHandlerCompletedAction {
        case fireErrorCaughtAndStartUnbuffering(Error)
        case removeHandler(UpgradeResult)
        case fireErrorCaughtAndRemoveHandler(Error)
        case startUnbuffering(UpgradeResult)
    }

    @inlinable
    mutating func upgradingHandlerCompleted(_ result: Result<UpgradeResult, Error>) -> UpgradingHandlerCompletedAction?
    {
        switch self.state {
        case .initial, .awaitingUpgradeResponseHead, .awaitingUpgradeResponseEnd, .unbuffering:
            fatalError("Internal inconsistency in HTTPClientUpgradeStateMachine")

        case .upgrading(let upgrading):
            switch result {
            case .success(let value):
                if !upgrading.buffer.isEmpty {
                    self.state = .unbuffering(.init(buffer: upgrading.buffer))
                    return .startUnbuffering(value)
                } else {
                    self.state = .finished
                    return .removeHandler(value)
                }

            case .failure(let error):
                if !upgrading.buffer.isEmpty {
                    // So we failed to upgrade. There is nothing really that we can do here.
                    // We are unbuffering the reads but there shouldn't be any handler in the pipeline
                    // that expects a specific type of reads anyhow.
                    self.state = .unbuffering(.init(buffer: upgrading.buffer))
                    return .fireErrorCaughtAndStartUnbuffering(error)
                } else {
                    self.state = .finished
                    return .fireErrorCaughtAndRemoveHandler(error)
                }
            }

        case .finished:
            // We have to tolerate this
            return nil

        case .modifying:
            fatalError("Internal inconsistency in HTTPClientUpgradeStateMachine")
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
        case .initial, .awaitingUpgradeResponseHead, .awaitingUpgradeResponseEnd, .upgrading, .finished:
            preconditionFailure("Invalid state \(self.state)")

        case .unbuffering(var unbuffering):
            self.state = .modifying

            if let element = unbuffering.buffer.popFirst() {
                self.state = .unbuffering(unbuffering)

                return .fireChannelRead(element)
            } else {
                self.state = .finished

                return .fireChannelReadCompleteAndRemoveHandler
            }

        case .modifying:
            fatalError("Internal inconsistency in HTTPClientUpgradeStateMachine")

        }
    }
}
