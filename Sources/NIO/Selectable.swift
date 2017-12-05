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
protocol Selectable {
    
    /// The file descriptor itself.
    var descriptor: Int32 { get }

    /// `true` if this `Selectable` is open (which means it was not closed yet).
    var open: Bool { get }

    /// Close this `Selectable` (and so its `descriptor`).
    func close() throws
}
