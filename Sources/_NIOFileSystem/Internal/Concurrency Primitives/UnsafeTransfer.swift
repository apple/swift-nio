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

@usableFromInline
struct UnsafeTransfer<Value>: @unchecked Sendable {
    @usableFromInline
    var wrappedValue: Value

    @inlinable
    init(_ wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }
}
