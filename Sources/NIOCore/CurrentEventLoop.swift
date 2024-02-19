public struct CurrentEventLoop {
    public let wrapped: EventLoop
    @inlinable internal init(_ eventLoop: EventLoop) {
        self.wrapped = eventLoop
    }
}

@available(*, unavailable)
extension CurrentEventLoop: Sendable {}

extension EventLoop {
    @inlinable public func iKnowIAmOnThisEventLoop(
        file: StaticString = #file,
        line: UInt = #line
    ) -> CurrentEventLoop {
        self.preconditionInEventLoop(file: file, line: line)
        return .init(self)
    }
}

extension CurrentEventLoop {
    @inlinable
    public func execute(_ task: @escaping () -> Void) {
        wrapped.execute(task)
    }
    
    @inlinable
    public func submit<T>(_ task: @escaping () throws -> T) -> CurrentEventLoopFuture<T> {
        wrapped.submit(task).iKnowIAmOnTheEventLoopOfThisFuture()
    }
    
    @discardableResult
    @inlinable
    public func scheduleTask<T>(
        deadline: NIODeadline,
        _ task: @escaping () throws -> T
    ) -> ScheduledOnCurrentEventLoop<T> {
        wrapped.scheduleTask(deadline: deadline, task).iKnowIAmOnTheEventLoopOfThisScheduled()
    }
    @discardableResult
    @inlinable
    public func scheduleTask<T>(
        in delay: TimeAmount,
        _ task: @escaping () throws -> T
    ) -> ScheduledOnCurrentEventLoop<T> {
        wrapped.scheduleTask(in: delay, task).iKnowIAmOnTheEventLoopOfThisScheduled()
    }
    
    @discardableResult
    @inlinable
    public func flatScheduleTask<T>(
        deadline: NIODeadline,
        file: StaticString = #file,
        line: UInt = #line,
        _ task: @escaping () throws -> EventLoopFuture<T>
    ) -> ScheduledOnCurrentEventLoop<T> {
        wrapped.flatScheduleTask(deadline: deadline, file: file, line: line, task).iKnowIAmOnTheEventLoopOfThisScheduled()
    }
}

extension CurrentEventLoop {
    @inlinable
    public func makePromise<T>(of type: T.Type = T.self, file: StaticString = #file, line: UInt = #line) -> CurrentEventLoopPromise<T> {
        wrapped.makePromise(of: type, file: file, line: line).iKnowIAmOnTheEventLoopOfThisPromise()
    }
}

extension CurrentEventLoop {
    @discardableResult
    @inlinable
    public func makeSucceededVoidFuture() -> CurrentEventLoopFuture<Void> {
        wrapped.makeSucceededVoidFuture().iKnowIAmOnTheEventLoopOfThisFuture()
    }
    
    @inlinable
    public func makeFailedFuture<T>(_ error: Error) -> CurrentEventLoopFuture<T> {
        wrapped.makeFailedFuture(error).iKnowIAmOnTheEventLoopOfThisFuture()
    }
    
    @inlinable
    public func makeSucceededFuture<Success>(_ value: Success) -> CurrentEventLoopFuture<Success> {
        wrapped.makeSucceededFuture(value).iKnowIAmOnTheEventLoopOfThisFuture()
    }
    
    @inlinable
    public func makeCompletedFuture<Success>(_ result: Result<Success, Error>) -> CurrentEventLoopFuture<Success> {
        wrapped.makeCompletedFuture(result).iKnowIAmOnTheEventLoopOfThisFuture()
    }
}


