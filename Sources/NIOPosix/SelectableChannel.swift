//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOConcurrencyHelpers

/// A `SelectableChannel` is a `Channel` that can be used with a `Selector` which notifies a user when certain events
/// are possible. On UNIX a `Selector` is usually an abstraction of `select`, `poll`, `epoll` or `kqueue`.
///
/// - warning: `SelectableChannel` methods and properties are _not_ thread-safe (unless they also belong to `Channel`).
internal protocol SelectableChannel: Channel {
    /// The type of the `Selectable`. A `Selectable` is usually wrapping a file descriptor that can be registered in a
    /// `Selector`.
    associatedtype SelectableType: Selectable

    var isOpen: Bool { get }

    /// The event(s) of interest.
    var interestedEvent: SelectorEventSet { get }

    /// Called when the `SelectableChannel` is ready to be written.
    func writable()

    /// Called when the `SelectableChannel` is ready to be read.
    func readable()

    /// Called when the read side of the `SelectableChannel` hit EOF.
    func readEOF()

    /// Called when the write side of the `SelectableChannel` hit EOF.
    func writeEOF()

    /// Called when the `SelectableChannel` was reset (ie. is now unusable)
    func reset()

    func register(selector: Selector<NIORegistration>, interested: SelectorEventSet) throws

    func deregister(selector: Selector<NIORegistration>, mode: CloseMode) throws

    func reregister(selector: Selector<NIORegistration>, interested: SelectorEventSet) throws
}
