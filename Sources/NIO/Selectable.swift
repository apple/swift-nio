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

/// Represents a selectable resource which can be registered to a `Selector` to be notified once there are some events ready for it.
///
/// - warning: `Selectable`s are not thread-safe, only to be used on the appropriate `EventLoop`.
protocol Selectable {
    
    /// Will be called with the file descriptor of the `Selectable` if still open, if not it will
    /// throw an `IOError`.
    ///
    /// - parameters:
    ///     - body: The closure to execute if the `Selectable` is still open.
    /// - throws: If either the `Selectable` was closed before or the closure throws by itself.
    func withUnsafeFileDescriptor<T>(_ body: (Int32) throws -> T) throws -> T

    /// `true` if this `Selectable` is open (which means it was not closed yet).
    var open: Bool { get }

    /// Close this `Selectable` (and so its file descriptor).
    func close() throws
}
