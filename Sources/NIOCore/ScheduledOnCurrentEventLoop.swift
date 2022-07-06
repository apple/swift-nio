public struct ScheduledOnCurrentEventLoop<T> {
    public let wrapped: Scheduled<T>
    
    public var futureResult: CurrentEventLoopFuture<T> {
        wrapped.futureResult.iKnowIAmOnTheEventLoopOfThisFuture()
    }
    
    @inlinable init(_ scheduled: Scheduled<T>) {
        self.wrapped = scheduled
    }
    
    @inlinable
    public init(promise: CurrentEventLoopPromise<T>, cancellationTask: @escaping () -> Void) {
        wrapped = .init(promise: promise.wrapped, cancellationTask: cancellationTask)
    }
    
    @inlinable
    public func cancel() {
        wrapped.cancel()
    }
}

#if swift(>=5.6)
@available(*, unavailable)
extension ScheduledOnCurrentEventLoop: Sendable {}
#endif

extension Scheduled {
    @inlinable public func iKnowIAmOnTheEventLoopOfThisScheduled(
        file: StaticString = #file,
        line: UInt = #line
    ) -> ScheduledOnCurrentEventLoop<T> {
        self.futureResult.eventLoop.preconditionInEventLoop(file: file, line: line)
        return .init(self)
    }
}
