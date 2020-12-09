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

import NIO

// note: We have to define the variable `hasAsyncAwait` here because if we copy this code into the property below,
// it doesn't compile on Swift 5.0.
#if compiler(>=5.4)
#if compiler(>=5.4) // we cannot write this on one line with `&&` because Swift 5.0 doesn't like it...
fileprivate let hasAsyncAwait = true
#else
fileprivate let hasAsyncAwait = false
#endif
#else
fileprivate let hasAsyncAwait = false
#endif

extension NIO.System {
    public static var hasAsyncAwaitSupport: Bool {
        return hasAsyncAwait
    }
}
