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

/// A tag protocol that can be used to cover events used to boostrap VSOCK channels.
///
/// Users are strongly encouraged not to conform their own types to this protocol.
public protocol VsockChannelEvent: Hashable, Sendable {}

enum VsockChannelEvents {
    /// Fired as an outbound event when NIO would like to ask itself to bind the socket.
    ///
    /// This flow for connect is required because we cannot extend `enum SocketAddress` without
    /// breaking public API.
    struct BindToAddress: VsockChannelEvent {
        public var address: VsockAddress

        public init(_ address: VsockAddress) {
            self.address = address
        }
    }

    /// Fired as an outbound event when NIO would like to ask itself to connect the socket.
    ///
    /// This flow for connect is required because we cannot extend `enum SocketAddress` without
    /// breaking public API.
    struct ConnectToAddress: VsockChannelEvent {
        public var address: VsockAddress

        public init(_ address: VsockAddress) {
            self.address = address
        }
    }
}
