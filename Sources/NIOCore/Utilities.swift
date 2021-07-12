//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// A utility function that runs the body code only in debug builds, without
/// emitting compiler warnings.
///
/// This is currently the only way to do this in Swift: see
/// https://forums.swift.org/t/support-debug-only-code/11037 for a discussion.
@inlinable
internal func debugOnly(_ body: () -> Void) {
    // FIXME: duplicated with NIO.
    assert({ body(); return true }())
}
