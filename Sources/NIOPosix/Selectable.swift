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

/// Represents a selectable resource which can be registered to a `Selector` to
/// be notified once there are some events ready for it.
///
/// - warning:
///     `Selectable`s are not thread-safe, only to be used on the appropriate
///     `EventLoop`.
protocol Selectable {
    func withUnsafeHandle<T>(_: (NIOBSDSocket.Handle) throws -> T) throws -> T
}
