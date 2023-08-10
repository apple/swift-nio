public struct CurrentEventLoopFuture<Value> {
    public let wrapped: EventLoopFuture<Value>
    public var eventLoop: CurrentEventLoop {
        wrapped.eventLoop.iKnowIAmOnThisEventLoop()
    }
    @inlinable init(_ wrapped: EventLoopFuture<Value>) {
        self.wrapped = wrapped
    }
}

@available(*, unavailable)
extension CurrentEventLoopFuture: Sendable {}

extension EventLoopFuture {
    @inlinable public func iKnowIAmOnTheEventLoopOfThisFuture(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CurrentEventLoopFuture<Value> {
        self.eventLoop.preconditionInEventLoop(file: file, line: line)
        return .init(self)
    }
}

extension EventLoopFuture {
    @inlinable
    public func hop(to target: CurrentEventLoop) -> CurrentEventLoopFuture<Value> {
        self.hop(to: target.wrapped).iKnowIAmOnTheEventLoopOfThisFuture()
    }
}

extension CurrentEventLoopFuture {
    @inlinable public func flatMap<NewValue>(
        _ callback: @escaping (Value) -> EventLoopFuture<NewValue>
    ) -> CurrentEventLoopFuture<NewValue> {
        wrapped.flatMap(callback).iKnowIAmOnTheEventLoopOfThisFuture()
    }
    
    @inlinable public func flatMapThrowing<NewValue>(
        _ callback: @escaping @Sendable (Value) throws -> NewValue
    ) -> CurrentEventLoopFuture<NewValue> {
        wrapped.flatMapThrowing(callback).iKnowIAmOnTheEventLoopOfThisFuture()
    }
    @inlinable public func flatMapErrorThrowing(
        _ callback: @escaping (Error) throws -> Value
    ) -> CurrentEventLoopFuture<Value> {
        wrapped.flatMapErrorThrowing(callback).iKnowIAmOnTheEventLoopOfThisFuture()
    }
    @inlinable public func map<NewValue>(
        _ callback: @escaping (Value) -> (NewValue)
    ) -> CurrentEventLoopFuture<NewValue> {
        wrapped.map(callback).iKnowIAmOnTheEventLoopOfThisFuture()
    }
    @inlinable public func flatMapError(
        _ callback: @escaping (Error) -> EventLoopFuture<Value>
    ) -> CurrentEventLoopFuture<Value> {
        wrapped.flatMapError(callback).iKnowIAmOnTheEventLoopOfThisFuture()
    }
    @inlinable public func flatMapResult<NewValue, SomeError: Error>(
        _ body: @escaping (Value) -> Result<NewValue, SomeError>
    ) -> EventLoopFuture<NewValue> {
        wrapped.flatMapResult(body)
    }
    @inlinable public func recover(
        _ callback: @escaping (Error) -> Value
    ) -> EventLoopFuture<Value> {
        wrapped.recover(callback)
    }
    @inlinable public func whenSuccess(_ callback: @escaping (Value) -> Void) {
        wrapped.whenSuccess(callback)
    }
    @inlinable public func whenFailure(_ callback: @escaping (Error) -> Void) {
        wrapped.whenFailure(callback)
    }
    @inlinable public func whenComplete(
        _ callback: @escaping (Result<Value, Error>) -> Void
    ) {
        wrapped.whenComplete(callback)
    }
    @inlinable public func and<OtherValue>(
        _ other: EventLoopFuture<OtherValue>
    ) -> CurrentEventLoopFuture<(Value, OtherValue)> {
        wrapped.and(other).iKnowIAmOnTheEventLoopOfThisFuture()
    }
    @inlinable public func always(
        _ callback: @escaping (Result<Value, Error>) -> Void
    ) -> CurrentEventLoopFuture<Value> {
        wrapped.always(callback).iKnowIAmOnTheEventLoopOfThisFuture()
    }
    @inlinable public func unwrap<NewValue>(
        orError error: Error
    ) -> CurrentEventLoopFuture<NewValue> where Value == Optional<NewValue> {
        wrapped.unwrap(orError: error).iKnowIAmOnTheEventLoopOfThisFuture()
    }
    @inlinable public func unwrap<NewValue>(
        orReplace replacement: NewValue
    ) -> CurrentEventLoopFuture<NewValue> where Value == Optional<NewValue> {
        wrapped.unwrap(orReplace: replacement).iKnowIAmOnTheEventLoopOfThisFuture()
    }
    @inlinable public func unwrap<NewValue>(
        orElse callback: @escaping () -> NewValue
    ) -> CurrentEventLoopFuture<NewValue> where Value == Optional<NewValue> {
        wrapped.unwrap(orElse: callback).iKnowIAmOnTheEventLoopOfThisFuture()
    }
}

// static methods missing: fold, reduce, andAllSucceed, whenAllSucceed, andAllComplete
