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

extension EventLoop {
    @inlinable
    @available(*, deprecated, message: "Please don't pass file:line:, there's no point.")
    public func makeFailedFuture<T>(_ error: Error, file: StaticString = #file, line: UInt = #line) -> EventLoopFuture<T> {
        return self.makeFailedFuture(error)
    }

    @inlinable
    @available(*, deprecated, message: "Please don't pass file:line:, there's no point.")
    public func makeSucceededFuture<Success>(_ value: Success, file: StaticString = #file, line: UInt = #line) -> EventLoopFuture<Success> {
        return self.makeSucceededFuture(value)
    }
}
