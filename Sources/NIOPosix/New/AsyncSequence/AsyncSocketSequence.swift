import NIOCore

struct AsyncSocketSequence: AsyncSequence {
    typealias Element = ByteBuffer
    private let socket: Socket
    private let executor: IOExecutor

    internal init(socket: Socket, executor: IOExecutor) {
        self.socket = socket
        self.executor = executor
    }

    func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(socket: self.socket, executor: self.executor)
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate enum State {
            fileprivate struct Running {
                fileprivate let socket: Socket
                fileprivate let allocator: ByteBufferAllocator
                fileprivate var pooledAllocator: PooledRecvBufferAllocator
                fileprivate let executor: IOExecutor
                fileprivate var seenReadEOF = false
            }
            case running(Running)
            case finished
        }

        private var state: State

        init(socket: Socket, executor: IOExecutor) {
            self.state = .running(.init(
                socket: socket,
                allocator: .init(), // TODO: Inject
                pooledAllocator: .init(capacity: 10, recvAllocator: AdaptiveRecvByteBufferAllocator()),  // TODO: Inject
                executor: executor)
            )

        }
        mutating func next() async throws -> Element? {
            // TODO: At best we would want to use `withTaskExecutorPreference` here but it is currently wrongly marked @Sendable
            switch self.state {
            case .running(var running):
                running.executor.preconditionOnExecutor()

                while true {
                    let socket = running.socket
                    let (buffer, result) = try running.pooledAllocator.buffer(
                        allocator: running.allocator
                    ) { buffer in
                        try buffer.withMutableWritePointer {
                            try socket.read(pointer: $0)
                        }
                    }
                    switch result {
                    case .wouldBlock:
                        do {
                            // TODO: How should we handle cancellation here?
                            let eventSet = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SelectorEventSet, Error>) in
                                do {
                                    try running.executor.reregister(
                                        selectable: running.socket
                                    ) { registration in
                                        registration.interested.insert(.read)
                                        registration.interested.insert(.readEOF)
                                        registration.readContinuation = continuation
                                    }
                                } catch {
                                    continuation.resume(with: .failure(error))
                                }
                            }

                            if eventSet.contains(.readEOF) {
                                // We got a readEOF from the selector but there might still be data to
                                // read from the socket so we are going to continue looping until we
                                // get a zero byte read.
                                running.seenReadEOF = true
                                self.state = .running(running)
                                continue
                            }


                            if eventSet.contains(.read) {
                                // We got a read event so let's try to read from the socket again
                                continue
                            }


                            // We have to unregister for read and readEOF now after we got it
                            try running.executor.reregister(selectable: running.socket) { registration in
                                registration.interested.subtract(.read)
                                registration.interested.subtract(.readEOF)
                            }
                        } catch {
                            // We got an error while trying to re-register
                            // that means the selector is closed and we just throw whatever error
                            // we have up the chain
                            self.state = .finished
                            throw error
                        }
                    case .processed:
                        if buffer.readableBytes == 0 {
                            // Reading a 0 byte buffer means that we received a TCP FIN. We can
                            // transition to finished and return nil now
                            self.state = .finished
                            return nil
                        }
                        return buffer
                    }
                }
            case .finished:
                return nil
            }
        }
    }
}
