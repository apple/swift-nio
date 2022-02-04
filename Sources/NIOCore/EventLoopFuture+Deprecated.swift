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

extension EventLoopFuture {
    @inlinable
    @available(*, deprecated, message: "Please don't pass file:line:, there's no point.")
    public func flatMap<NewValue>(file: StaticString = #file, line: UInt = #line, _ callback: @escaping (Value) -> EventLoopFuture<NewValue>) -> EventLoopFuture<NewValue> {
        return self.flatMap(callback)
    }

    @inlinable
    @available(*, deprecated, message: "Please don't pass file:line:, there's no point.")
    public func flatMapThrowing<NewValue>(file: StaticString = #file,
                                line: UInt = #line,
                                _ callback: @escaping (Value) throws -> NewValue) -> EventLoopFuture<NewValue> {
        return self.flatMapThrowing(callback)
    }

    @inlinable
    @available(*, deprecated, message: "Please don't pass file:line:, there's no point.")
    public func flatMapErrorThrowing(file: StaticString = #file, line: UInt = #line, _ callback: @escaping (Error) throws -> Value) -> EventLoopFuture<Value> {
        return self.flatMapErrorThrowing(callback)
    }

    @inlinable
    @available(*, deprecated, message: "Please don't pass file:line:, there's no point.")
    public func map<NewValue>(file: StaticString = #file, line: UInt = #line, _ callback: @escaping (Value) -> (NewValue)) -> EventLoopFuture<NewValue> {
        return self.map(callback)
    }

    @inlinable
    @available(*, deprecated, message: "Please don't pass file:line:, there's no point.")
    public func flatMapError(file: StaticString = #file, line: UInt = #line, _ callback: @escaping (Error) -> EventLoopFuture<Value>) -> EventLoopFuture<Value> {
        return self.flatMapError(callback)
    }

    @inlinable
    @available(*, deprecated, message: "Please don't pass file:line:, there's no point.")
    public func flatMapResult<NewValue, SomeError: Error>(file: StaticString = #file,
                                                          line: UInt = #line,
                                                          _ body: @escaping (Value) -> Result<NewValue, SomeError>) -> EventLoopFuture<NewValue> {
        return self.flatMapResult(body)
    }

    @inlinable
    @available(*, deprecated, message: "Please don't pass file:line:, there's no point.")
    public func recover(file: StaticString = #file, line: UInt = #line, _ callback: @escaping (Error) -> Value) -> EventLoopFuture<Value> {
        return self.recover(callback)
    }

    @inlinable
    @available(*, deprecated, message: "Please don't pass file:line:, there's no point.")
    public func and<OtherValue>(_ other: EventLoopFuture<OtherValue>,
                                file: StaticString = #file,
                                line: UInt = #line) -> EventLoopFuture<(Value, OtherValue)> {
        return self.and(other)
    }

    @inlinable
    @available(*, deprecated, message: "Please don't pass file:line:, there's no point.")
    public func and<OtherValue>(value: OtherValue,
                                file: StaticString = #file,
                                line: UInt = #line) -> EventLoopFuture<(Value, OtherValue)> {
        return self.and(value: value)
    }
}
