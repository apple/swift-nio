//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// A Copy on Write (CoW) type that can be used in tests to assert in-place mutation
struct CoWValue: @unchecked Sendable {
    private final class UniquenessIndicator {}

    /// This reference is "copied" if not uniquely referenced
    private var uniquenessIndicator = UniquenessIndicator()

    /// mutates `self` and returns a boolean whether it was mutated in place or not
    /// - Returns: true if mutation happened in-place, false if Copy on Write (CoW) was triggered
    mutating func mutateInPlace() -> Bool {
        guard isKnownUniquelyReferenced(&self.uniquenessIndicator) else {
            self.uniquenessIndicator = UniquenessIndicator()
            return false
        }
        return true
    }
}
