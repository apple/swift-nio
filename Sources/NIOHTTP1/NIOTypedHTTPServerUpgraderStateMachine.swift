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
struct NIOTypedHTTPServerUpgraderStateMachine<UpgradeResult> {
    @usableFromInline
    enum State {
        /// The state before we received a TLSUserEvent. We are just forwarding any read at this point.
        case initial

        enum BufferedState {
            case data(NIOAny)
            case inputClosed
        }

        @usableFromInline
        struct AwaitingUpgrader {
            var seenFirstRequest: Bool
            var buffer: Deque<BufferedState>
        }

        /// The request head has been received. We're currently running the future chain awaiting an upgrader.
        case awaitingUpgrader(AwaitingUpgrader)

        @usableFromInline
        struct UpgraderReady {
            var upgrader: any NIOTypedHTTPServerProtocolUpgrader<UpgradeResult>
            var requestHead: HTTPRequestHead
            var responseHeaders: HTTPHeaders
            var proto: String
            var buffer: Deque<BufferedState>
        }

        /// We have an upgrader, which means we can begin upgrade we are just waiting for the request end.
        case upgraderReady(UpgraderReady)

        @usableFromInline
        struct Upgrading {
            var buffer: Deque<BufferedState>
        }
        /// We are either running the upgrading handler.
        case upgrading(Upgrading)

        @usableFromInline
        struct Unbuffering {
            var buffer: Deque<BufferedState>
        }
        case unbuffering(Unbuffering)

        case finished

        case modifying
    }

    private var state = State.initial

    @usableFromInline
    enum HandlerRemovedAction {
        case failUpgradePromise
    }

    @inlinable
    mutating func handlerRemoved() -> HandlerRemovedAction? {
        switch self.state {
        case .initial, .awaitingUpgrader, .upgraderReady, .upgrading, .unbuffering:
            self.state = .finished
            return .failUpgradePromise

        case .finished:
            return .none

        case .modifying:
            fatalError("Internal inconsistency in HTTPServerUpgradeStateMachine")
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

        case .awaitingUpgrader(var awaitingUpgrader):
            if awaitingUpgrader.seenFirstRequest {
                // We should buffer the data since we have seen the full request.
                self.state = .modifying
                awaitingUpgrader.buffer.append(.data(data))
                self.state = .awaitingUpgrader(awaitingUpgrader)
                return nil
            } else {
                // We shouldn't buffer. This means we are still expecting HTTP parts.
                return .unwrapData
            }

        case .upgraderReady:
            // We have not seen the end of the HTTP request so this
            // data is probably an HTTP request part.
            return .unwrapData

        case .unbuffering(var unbuffering):
            self.state = .modifying
            unbuffering.buffer.append(.data(data))
            self.state = .unbuffering(unbuffering)
            return nil

        case .finished:
            return .fireChannelRead

        case .upgrading(var upgrading):
            // We got a read while running ugprading.
            // We have to buffer the read to unbuffer it afterwards
            self.state = .modifying
            upgrading.buffer.append(.data(data))
            self.state = .upgrading(upgrading)
            return nil

        case .modifying:
            fatalError("Internal inconsistency in HTTPServerUpgradeStateMachine")
        }
    }

    @usableFromInline
    enum ChannelReadRequestPartAction {
        case failUpgradePromise(Error)
        case runNotUpgradingInitializer
        case startUpgrading(
            upgrader: any NIOTypedHTTPServerProtocolUpgrader<UpgradeResult>,
            requestHead: HTTPRequestHead,
            responseHeaders: HTTPHeaders,
            proto: String
        )
        case findUpgrader(
            head: HTTPRequestHead,
            requestedProtocols: [String],
            allHeaderNames: Set<String>,
            connectionHeader: Set<String>
        )
    }

    @inlinable
    mutating func channelReadRequestPart(_ requestPart: HTTPServerRequestPart) -> ChannelReadRequestPartAction? {
        switch self.state {
        case .initial:
            guard case .head(let head) = requestPart else {
                // The first data that we saw was not a head. This is a protocol error and we are just going to
                // fail upgrading
                return .failUpgradePromise(HTTPServerUpgradeErrors.invalidHTTPOrdering)
            }

            // Ok, we have a HTTP head. Check if it's an upgrade.
            let requestedProtocols = head.headers[canonicalForm: "upgrade"].map(String.init)
            guard requestedProtocols.count > 0 else {
                // We have to buffer now since we got the request head but are not upgrading.
                // The user is configuring the HTTP pipeline now.
                var buffer = Deque<State.BufferedState>()
                buffer.append(.data(NIOAny(requestPart)))
                self.state = .upgrading(.init(buffer: buffer))
                return .runNotUpgradingInitializer
            }

            // We can now transition to awaiting the upgrader. This means that we are trying to
            // find an upgrade that can handle requested protocols. We are not buffering because
            // we are waiting for the request end.
            self.state = .awaitingUpgrader(.init(seenFirstRequest: false, buffer: .init()))

            let connectionHeader = Set(head.headers[canonicalForm: "connection"].map { $0.lowercased() })
            let allHeaderNames = Set(head.headers.map { $0.name.lowercased() })

            return .findUpgrader(
                head: head,
                requestedProtocols: requestedProtocols,
                allHeaderNames: allHeaderNames,
                connectionHeader: connectionHeader
            )

        case .awaitingUpgrader(let awaitingUpgrader):
            switch (awaitingUpgrader.seenFirstRequest, requestPart) {
            case (true, _):
                // This is weird we are seeing more requests parts after we have seen an end
                // Let's fail upgrading
                return .failUpgradePromise(HTTPServerUpgradeErrors.invalidHTTPOrdering)

            case (false, .head):
                // This is weird we are seeing another head but haven't seen the end for the request before
                return .failUpgradePromise(HTTPServerUpgradeErrors.invalidHTTPOrdering)

            case (false, .body):
                // This is weird we are seeing body parts for a request that indicated that it wanted
                // to upgrade.
                return .failUpgradePromise(HTTPServerUpgradeErrors.invalidHTTPOrdering)

            case (false, .end):
                // Okay we got the end as expected. Just gotta store this in our state.
                self.state = .awaitingUpgrader(.init(seenFirstRequest: true, buffer: awaitingUpgrader.buffer))
                return nil
            }

        case .upgraderReady(let upgraderReady):
            switch requestPart {
            case .head:
                // This is weird we are seeing another head but haven't seen the end for the request before
                return .failUpgradePromise(HTTPServerUpgradeErrors.invalidHTTPOrdering)

            case .body:
                // This is weird we are seeing body parts for a request that indicated that it wanted
                // to upgrade.
                return .failUpgradePromise(HTTPServerUpgradeErrors.invalidHTTPOrdering)

            case .end:
                // Okay we got the end as expected and our upgrader is ready so let's start upgrading
                self.state = .upgrading(.init(buffer: upgraderReady.buffer))
                return .startUpgrading(
                    upgrader: upgraderReady.upgrader,
                    requestHead: upgraderReady.requestHead,
                    responseHeaders: upgraderReady.responseHeaders,
                    proto: upgraderReady.proto
                )
            }

        case .upgrading, .unbuffering, .finished:
            fatalError("Internal inconsistency in HTTPServerUpgradeStateMachine")

        case .modifying:
            fatalError("Internal inconsistency in HTTPServerUpgradeStateMachine")
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
        case .initial:
            fatalError("Internal inconsistency in HTTPServerUpgradeStateMachine")

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

        case .awaitingUpgrader, .upgraderReady, .unbuffering:
            fatalError("Internal inconsistency in HTTPServerUpgradeStateMachine")

        case .modifying:
            fatalError("Internal inconsistency in HTTPServerUpgradeStateMachine")
        }
    }

    @usableFromInline
    enum FindingUpgraderCompletedAction {
        case startUpgrading(
            upgrader: any NIOTypedHTTPServerProtocolUpgrader<UpgradeResult>,
            responseHeaders: HTTPHeaders,
            proto: String
        )
        case runNotUpgradingInitializer
        case fireErrorCaughtAndStartUnbuffering(Error)
        case fireErrorCaughtAndRemoveHandler(Error)
    }

    @inlinable
    mutating func findingUpgraderCompleted(
        requestHead: HTTPRequestHead,
        _ result: Result<
            (
                upgrader: any NIOTypedHTTPServerProtocolUpgrader<UpgradeResult>,
                responseHeaders: HTTPHeaders,
                proto: String
            )?,
            Error
        >
    ) -> FindingUpgraderCompletedAction? {
        switch self.state {
        case .initial, .upgraderReady:
            fatalError("Internal inconsistency in HTTPServerUpgradeStateMachine")

        case .awaitingUpgrader(let awaitingUpgrader):
            switch result {
            case .success(.some((let upgrader, let responseHeaders, let proto))):
                if awaitingUpgrader.seenFirstRequest {
                    // We have seen the end of the request. So we can upgrade now.
                    self.state = .upgrading(.init(buffer: awaitingUpgrader.buffer))
                    return .startUpgrading(upgrader: upgrader, responseHeaders: responseHeaders, proto: proto)
                } else {
                    // We have not yet seen the end so we have to wait until that happens
                    self.state = .upgraderReady(
                        .init(
                            upgrader: upgrader,
                            requestHead: requestHead,
                            responseHeaders: responseHeaders,
                            proto: proto,
                            buffer: awaitingUpgrader.buffer
                        )
                    )
                    return nil
                }

            case .success(.none):
                // There was no upgrader to handle the request. We just run the not upgrading
                // initializer now.
                self.state = .upgrading(.init(buffer: awaitingUpgrader.buffer))
                return .runNotUpgradingInitializer

            case .failure(let error):
                if !awaitingUpgrader.buffer.isEmpty {
                    self.state = .unbuffering(.init(buffer: awaitingUpgrader.buffer))
                    return .fireErrorCaughtAndStartUnbuffering(error)
                } else {
                    self.state = .finished
                    return .fireErrorCaughtAndRemoveHandler(error)
                }
            }

        case .upgrading, .unbuffering, .finished:
            fatalError("Internal inconsistency in HTTPServerUpgradeStateMachine")

        case .modifying:
            fatalError("Internal inconsistency in HTTPServerUpgradeStateMachine")
        }
    }

    @usableFromInline
    enum UnbufferAction {
        case close
        case fireChannelRead(NIOAny)
        case fireChannelReadCompleteAndRemoveHandler
        case fireInputClosedEvent
    }

    @inlinable
    mutating func unbuffer() -> UnbufferAction {
        switch self.state {
        case .initial, .awaitingUpgrader, .upgraderReady, .upgrading, .finished:
            preconditionFailure("Invalid state \(self.state)")

        case .unbuffering(var unbuffering):
            self.state = .modifying

            if let element = unbuffering.buffer.popFirst() {
                self.state = .unbuffering(unbuffering)
                switch element {
                case .data(let data):
                    return .fireChannelRead(data)
                case .inputClosed:
                    return .fireInputClosedEvent
                }
            } else {
                self.state = .finished

                return .fireChannelReadCompleteAndRemoveHandler
            }

        case .modifying:
            fatalError("Internal inconsistency in HTTPServerUpgradeStateMachine")

        }
    }

    @usableFromInline
    enum InputClosedAction {
        case close
        case `continue`
        case fireInputClosedEvent
    }

    @inlinable
    mutating func inputClosed() -> InputClosedAction {
        switch self.state {
        case .initial:
            self.state = .finished
            return .close

        case .awaitingUpgrader(var awaitingUpgrader):
            if awaitingUpgrader.seenFirstRequest {
                // We should buffer the input close since we have seen the full request.
                awaitingUpgrader.buffer.append(.inputClosed)
                self.state = .awaitingUpgrader(awaitingUpgrader)
                return .continue
            } else {
                // We shouldn't buffer. This means we were still expecting HTTP parts.
                return .close
            }

        case .upgrading(var upgrading):
            upgrading.buffer.append(.inputClosed)
            self.state = .upgrading(upgrading)
            return .continue

        case .upgraderReady:
            // if the state is `upgraderReady` we have received a `.head` but not an `.end`.
            // If input is closed then there is no way to move this forward so we should
            // close.
            self.state = .finished
            return .close

        case .unbuffering(var unbuffering):
            unbuffering.buffer.append(.inputClosed)
            self.state = .unbuffering(unbuffering)
            return .continue

        case .finished:
            return .fireInputClosedEvent

        case .modifying:
            fatalError("Internal inconsistency in HTTPServerUpgradeStateMachine")
        }
    }

}
