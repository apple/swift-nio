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

public protocol ChannelInboundHandler: _ChannelInboundHandler {
    associatedtype InboundIn
    associatedtype InboundUserEventIn = Never

    associatedtype OutboundOut = Never
    associatedtype InboundOut = Never
    associatedtype OutboundUserEventOut = Never
    associatedtype InboundUserEventOut = Never

    func unwrapInboundIn(_ value: IOData) -> InboundIn
    func tryUnwrapInboundIn(_ value: IOData) -> InboundIn?
    func wrapInboundOut(_ value: InboundOut) -> IOData
    func unwrapInboundUserEventIn(_ value: Any) -> InboundUserEventIn
    func tryUnwrapInboundUserEventIn(_ value: Any) -> InboundUserEventIn?
    func wrapInboundUserEventOut(_ value: InboundUserEventOut) -> Any
    func wrapOutboundOut(_ value: OutboundOut) -> IOData
}

public extension ChannelInboundHandler {
    func unwrapInboundIn(_ value: IOData) -> InboundIn {
        return value.forceAs()
    }

    func tryUnwrapInboundIn(_ value: IOData) -> InboundIn? {
        return value.forceAs()
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

    func wrapOutboundOut(_ value: OutboundOut) -> IOData {
        return IOData(value)
    }

}

public protocol ChannelOutboundHandler: _ChannelOutboundHandler {
    associatedtype OutboundIn
    associatedtype OutboundUserEventIn = Never

    associatedtype OutboundOut
    associatedtype InboundOut = Never
    associatedtype OutboundUserEventOut = Never
    associatedtype InboundUserEventOut = Never

    func unwrapOutboundIn(_ value: IOData) -> OutboundIn
    func tryUnwrapOutboundIn(_ value: IOData) -> OutboundIn?
    func wrapOutboundOut(_ value: OutboundOut) -> IOData

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

    func wrapOutboundOut(_ value: OutboundOut) -> IOData {
        return IOData(value)
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
