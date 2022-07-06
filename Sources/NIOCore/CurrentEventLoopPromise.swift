public struct CurrentEventLoopPromise<Value> {
    public let wrapped: EventLoopPromise<Value>
    
    @inlinable public var futureResult: CurrentEventLoopFuture<Value> {
        wrapped.futureResult.iKnowIAmOnTheEventLoopOfThisFuture()
    }
    
    @inlinable
    init(_ promise: EventLoopPromise<Value>) {
        self.wrapped = promise
    }
}

#if swift(>=5.6)
@available(*, unavailable)
extension CurrentEventLoopPromise: Sendable {}
#endif

extension EventLoopPromise {
    @inlinable public func iKnowIAmOnTheEventLoopOfThisPromise(
        file: StaticString = #file,
        line: UInt = #line
    ) -> CurrentEventLoopPromise<Value> {
        self.futureResult.eventLoop.preconditionInEventLoop(file: file, line: line)
        return .init(self)
    }
}

extension CurrentEventLoopPromise {
    @inlinable
    public func succeed(_ value: Value) {
        self.wrapped.succeed(value)
    }

    @inlinable
    public func fail(_ error: Error) {
        self.wrapped.fail(error)
    }
    
    @inlinable
    public func completeWith(_ result: Result<Value, Error>) {
        self.wrapped.completeWith(result)
    }
}
