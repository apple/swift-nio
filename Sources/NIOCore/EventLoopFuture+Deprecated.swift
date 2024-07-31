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
    public func flatMap<NewValue>(
        file: StaticString = #fileID,
        line: UInt = #line,
        _ callback: @escaping (Value) -> EventLoopFuture<NewValue>
    ) -> EventLoopFuture<NewValue> {
        self.flatMap(callback)
    }

    @inlinable
    @available(*, deprecated, message: "Please don't pass file:line:, there's no point.")
    public func flatMapThrowing<NewValue>(
        file: StaticString = #fileID,
        line: UInt = #line,
        _ callback: @escaping (Value) throws -> NewValue
    ) -> EventLoopFuture<NewValue> {
        self.flatMapThrowing(callback)
    }

    @inlinable
    @available(*, deprecated, message: "Please don't pass file:line:, there's no point.")
    public func flatMapErrorThrowing(
        file: StaticString = #fileID,
        line: UInt = #line,
        _ callback: @escaping (Error) throws -> Value
    ) -> EventLoopFuture<Value> {
        self.flatMapErrorThrowing(callback)
    }

    @inlinable
    @available(*, deprecated, message: "Please don't pass file:line:, there's no point.")
    public func map<NewValue>(
        file: StaticString = #fileID,
        line: UInt = #line,
        _ callback: @escaping (Value) -> (NewValue)
    ) -> EventLoopFuture<NewValue> {
        self.map(callback)
    }

    @inlinable
    @available(*, deprecated, message: "Please don't pass file:line:, there's no point.")
    public func flatMapError(
        file: StaticString = #fileID,
        line: UInt = #line,
        _ callback: @escaping (Error) -> EventLoopFuture<Value>
    ) -> EventLoopFuture<Value> {
        self.flatMapError(callback)
    }

    @inlinable
    @available(*, deprecated, message: "Please don't pass file:line:, there's no point.")
    public func flatMapResult<NewValue, SomeError: Error>(
        file: StaticString = #fileID,
        line: UInt = #line,
        _ body: @escaping (Value) -> Result<NewValue, SomeError>
    ) -> EventLoopFuture<NewValue> {
        self.flatMapResult(body)
    }

    @inlinable
    @available(*, deprecated, message: "Please don't pass file:line:, there's no point.")
    public func recover(
        file: StaticString = #fileID,
        line: UInt = #line,
        _ callback: @escaping (Error) -> Value
    ) -> EventLoopFuture<Value> {
        self.recover(callback)
    }

    @inlinable
    @available(*, deprecated, message: "Please don't pass file:line:, there's no point.")
    public func and<OtherValue>(
        _ other: EventLoopFuture<OtherValue>,
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> EventLoopFuture<(Value, OtherValue)> {
        self.and(other)
    }

    @inlinable
    @available(*, deprecated, message: "Please don't pass file:line:, there's no point.")
    public func and<OtherValue>(
        value: OtherValue,
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> EventLoopFuture<(Value, OtherValue)> {
        self.and(value: value)
    }
}
