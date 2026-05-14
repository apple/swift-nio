//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import Testing

@testable import NIOHTTP1

struct HTTPServerUpgraderStateMachineTests {
    struct TestUpgrader: NIOTypedHTTPServerProtocolUpgrader<Bool> {
        var supportedProtocol: String { "bool" }
        var requiredUpgradeHeaders: [String] { [] }
        func buildUpgradeResponse(
            channel: Channel,
            upgradeRequest: HTTPRequestHead,
            initialResponseHeaders: HTTPHeaders
        ) -> EventLoopFuture<HTTPHeaders> {
            channel.eventLoop.makeSucceededFuture(initialResponseHeaders)
        }
        func upgrade(
            channel: Channel,
            upgradeRequest: HTTPRequestHead
        ) -> EventLoopFuture<UpgradeResult> {
            channel.eventLoop.makeSucceededFuture(true)
        }
    }

    @Test
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    func upgrade() {
        var stateMachine = NIOTypedHTTPServerUpgraderStateMachine<Bool>()
        let head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/ws",
            headers: ["upgrade": "bool", "connection": "upgrade"]
        )
        let headPart = HTTPServerRequestPart.head(head)
        #expect(stateMachine.channelReadData(NIOAny(headPart)) == .unwrapData)
        let readRequestPartAction = stateMachine.channelReadRequestPart(headPart)
        guard case .findUpgrader = readRequestPartAction else {
            Issue.record("Unexpected channelReadRequestPart action")
            return
        }
        #expect(stateMachine.channelReadData(NIOAny(HTTPServerRequestPart.end(nil))) == .unwrapData)
        #expect(stateMachine.channelReadRequestPart(HTTPServerRequestPart.end(nil)) == nil)
        let findingUpgraderCompletedAction = stateMachine.findingUpgraderCompleted(
            requestHead: head,
            .success((TestUpgrader(), [:], "bool"))
        )
        guard case .startUpgrading = findingUpgraderCompletedAction else {
            Issue.record("Unexpected findingUpgraderCompleted action")
            return
        }
        let upgradingHandlerCompletedAction = stateMachine.upgradingHandlerCompleted(.success(true))
        guard case .removeHandler = upgradingHandlerCompletedAction else {
            Issue.record("Unexpected upgradingHandlerCompletedAction action")
            return
        }
    }

    @Test
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    func noUpgrade() {
        var stateMachine = NIOTypedHTTPServerUpgraderStateMachine<Bool>()
        let head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/ws",
            headers: [:]
        )
        let headPart = HTTPServerRequestPart.head(head)
        #expect(stateMachine.channelReadData(NIOAny(headPart)) == .unwrapData)
        let readRequestPartAction = stateMachine.channelReadRequestPart(headPart)
        guard case .runNotUpgradingInitializer = readRequestPartAction else {
            Issue.record("Unexpected channelReadRequestPart action")
            return
        }
        #expect(stateMachine.channelReadData(NIOAny(HTTPServerRequestPart.end(nil))) == nil)
        let upgradingHandlerCompletedAction = stateMachine.upgradingHandlerCompleted(.success(false))
        guard case .startUnbuffering(false) = upgradingHandlerCompletedAction else {
            Issue.record("Unexpected upgradingHandlerCompleted action")
            return
        }
        var unbufferAction = stateMachine.unbuffer()
        guard case .fireChannelRead = unbufferAction else {
            Issue.record("Unexpected unbufferAction action")
            return
        }
        unbufferAction = stateMachine.unbuffer()
        guard case .fireChannelRead = unbufferAction else {
            Issue.record("Unexpected unbufferAction action")
            return
        }
        unbufferAction = stateMachine.unbuffer()
        guard case .fireChannelReadCompleteAndRemoveHandler = unbufferAction else {
            Issue.record("Unexpected unbufferAction action")
            return
        }
    }

    @Test
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    func upgradeFailedNoUpgrader() {
        struct UpgradeFail: Error {}
        var stateMachine = NIOTypedHTTPServerUpgraderStateMachine<Bool>()
        let head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/ws",
            headers: ["upgrade": "bool", "connection": "upgrade"]
        )
        let headPart = HTTPServerRequestPart.head(head)
        #expect(stateMachine.channelReadData(NIOAny(headPart)) == .unwrapData)
        let readRequestPartAction = stateMachine.channelReadRequestPart(headPart)
        guard case .findUpgrader = readRequestPartAction else {
            Issue.record("Unexpected channelReadRequestPart action")
            return
        }
        #expect(stateMachine.channelReadRequestPart(HTTPServerRequestPart.end(nil)) == nil)
        let findingUpgraderCompletedAction = stateMachine.findingUpgraderCompleted(
            requestHead: head,
            .failure(UpgradeFail())
        )
        guard case .fireErrorCaughtAndRemoveHandler = findingUpgraderCompletedAction else {
            Issue.record("Unexpected findingUpgraderCompleted action")
            return
        }
    }

    @Test
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    func upgradeReceiveEndAfterFindingUpgrader() {
        var stateMachine = NIOTypedHTTPServerUpgraderStateMachine<Bool>()
        let head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/ws",
            headers: ["upgrade": "bool", "connection": "upgrade"]
        )
        let headPart = HTTPServerRequestPart.head(head)
        #expect(stateMachine.channelReadData(NIOAny(headPart)) == .unwrapData)
        var readRequestPartAction = stateMachine.channelReadRequestPart(headPart)
        guard case .findUpgrader = readRequestPartAction else {
            Issue.record("Unexpected channelReadRequestPart action")
            return
        }
        #expect(
            stateMachine.findingUpgraderCompleted(
                requestHead: head,
                .success((TestUpgrader(), [:], "bool"))
            ) == nil
        )
        readRequestPartAction = stateMachine.channelReadRequestPart(HTTPServerRequestPart.end(nil))
        guard case .startUpgrading = readRequestPartAction else {
            Issue.record("Unexpected readRequestPartAction action")
            return
        }

        let upgradingHandlerCompletedAction = stateMachine.upgradingHandlerCompleted(.success(true))
        guard case .removeHandler = upgradingHandlerCompletedAction else {
            Issue.record("Unexpected upgradingHandlerCompletedAction action")
            return
        }
    }

    @Test
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    func removeHandlerWhileFindingUpgrader() {
        var stateMachine = NIOTypedHTTPServerUpgraderStateMachine<Bool>()
        let head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/ws",
            headers: ["upgrade": "bool", "connection": "upgrade"]
        )
        let headPart = HTTPServerRequestPart.head(head)
        #expect(stateMachine.channelReadData(NIOAny(headPart)) == .unwrapData)
        let readRequestPartAction = stateMachine.channelReadRequestPart(headPart)
        guard case .findUpgrader = readRequestPartAction else {
            Issue.record("Unexpected channelReadRequestPart action")
            return
        }
        #expect(stateMachine.channelReadRequestPart(HTTPServerRequestPart.end(nil)) == nil)
        #expect(stateMachine.handlerRemoved() == .failUpgradePromise)
        #expect(
            stateMachine.findingUpgraderCompleted(
                requestHead: head,
                .success((TestUpgrader(), [:], "bool"))
            ) == nil
        )
    }

    @Test
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    func removeHandlerWhileUpgrading() {
        var stateMachine = NIOTypedHTTPServerUpgraderStateMachine<Bool>()
        let head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/ws",
            headers: ["upgrade": "bool", "connection": "upgrade"]
        )
        let headPart = HTTPServerRequestPart.head(head)
        #expect(stateMachine.channelReadData(NIOAny(headPart)) == .unwrapData)
        let readRequestPartAction = stateMachine.channelReadRequestPart(headPart)
        guard case .findUpgrader = readRequestPartAction else {
            Issue.record("Unexpected channelReadRequestPart action")
            return
        }
        #expect(stateMachine.channelReadRequestPart(HTTPServerRequestPart.end(nil)) == nil)
        let findingUpgraderCompletedAction = stateMachine.findingUpgraderCompleted(
            requestHead: head,
            .success((TestUpgrader(), [:], "bool"))
        )
        guard case .startUpgrading = findingUpgraderCompletedAction else {
            Issue.record("Unexpected findingUpgraderCompleted action")
            return
        }
        #expect(stateMachine.handlerRemoved() == .failUpgradePromise)
        #expect(stateMachine.upgradingHandlerCompleted(.success(true)) == nil)
    }
}
