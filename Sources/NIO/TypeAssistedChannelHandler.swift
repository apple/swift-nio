//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

public protocol _EmittingChannelHandler {
    associatedtype OutboundOut = Never
    
    func wrapOutboundOut(_ value: OutboundOut) -> IOData
}

public extension _EmittingChannelHandler {
    func wrapOutboundOut(_ value: OutboundOut) -> IOData {
        return IOData(value)
    }
}

public protocol ChannelInboundHandler: _ChannelInboundHandler, _EmittingChannelHandler {
    associatedtype InboundIn
    associatedtype InboundUserEventIn = Never

    associatedtype InboundOut = Never
    associatedtype OutboundUserEventOut = Never
    associatedtype InboundUserEventOut = Never

    func unwrapInboundIn(_ value: IOData) -> InboundIn
    func tryUnwrapInboundIn(_ value: IOData) -> InboundIn?
    func wrapInboundOut(_ value: InboundOut) -> IOData
    func unwrapInboundUserEventIn(_ value: Any) -> InboundUserEventIn
    func tryUnwrapInboundUserEventIn(_ value: Any) -> InboundUserEventIn?
    func wrapInboundUserEventOut(_ value: InboundUserEventOut) -> Any
}

public extension ChannelInboundHandler {
    func unwrapInboundIn(_ value: IOData) -> InboundIn {
        return value.forceAs()
    }

    func tryUnwrapInboundIn(_ value: IOData) -> InboundIn? {
        return value.tryAs()
    }

    func wrapInboundOut(_ value: InboundOut) -> IOData {
        return IOData(value)
    }

    func unwrapInboundUserEventIn(_ value: Any) -> InboundUserEventIn {
        return value as! InboundUserEventIn
    }

    func tryUnwrapInboundUserEventIn(_ value: Any) -> InboundUserEventIn? {
        return value as? InboundUserEventIn
    }

    func wrapInboundUserEventOut(_ value: InboundUserEventOut) -> Any {
        return value
    }
}

public protocol ChannelOutboundHandler: _ChannelOutboundHandler, _EmittingChannelHandler {
    associatedtype OutboundIn
    associatedtype OutboundUserEventIn = Never

    associatedtype InboundOut = Never
    associatedtype OutboundUserEventOut = Never
    associatedtype InboundUserEventOut = Never

    func unwrapOutboundIn(_ value: IOData) -> OutboundIn
    func tryUnwrapOutboundIn(_ value: IOData) -> OutboundIn?

    func unwrapOutboundUserEventIn(_ value: Any) -> OutboundUserEventIn
    func tryUnwrapOutboundUserEventIn(_ value: Any) -> OutboundUserEventIn?
    func wrapOutboundUserEventOut(_ value: OutboundUserEventOut) -> Any
}

public extension ChannelOutboundHandler {
    func unwrapOutboundIn(_ value: IOData) -> OutboundIn {
        return value.forceAs()
    }

    func tryUnwrapOutboundIn(_ value: IOData) -> OutboundIn? {
        return value.tryAs()
    }

    func unwrapOutboundUserEventIn(_ value: Any) -> OutboundUserEventIn {
        return value as! OutboundUserEventIn
    }

    func tryUnwrapOutboundUserEventIn(_ value: Any) -> OutboundUserEventIn? {
        return value as? OutboundUserEventIn
    }

    func wrapOutboundUserEventOut(_ value: OutboundUserEventOut) -> Any {
        return value
    }
}
