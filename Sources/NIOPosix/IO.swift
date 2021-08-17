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

internal extension IOResult where T: FixedWidthInteger {
    var result: T {
        switch self {
        case .processed(let value):
            return value
        case .wouldBlock(_):
            fatalError("cannot unwrap IOResult")
        }
    }
}

/// An result for an IO operation that was done on a non-blocking resource.
enum IOResult<T: Equatable>: Equatable {

    /// Signals that the IO operation could not be completed as otherwise we would need to block.
    case wouldBlock(T)

    /// Signals that the IO operation was completed.
    case processed(T)
}
