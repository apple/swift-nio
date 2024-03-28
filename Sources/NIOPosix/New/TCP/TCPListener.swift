import NIOCore

public struct TCPListener: AsyncSequence {
    public typealias Element = TCPConnection

    public let localAddress: SocketAddress

    private let socket: ServerSocket
    private let executor: IOExecutor

    private init(socket: ServerSocket, executor: IOExecutor) throws {
        self.socket = socket
        self.executor = executor
        self.localAddress = try socket.localAddress()
    }

    public static func bind(
        executor: IOExecutor,
        host: String,
        port: Int,
        _ body: (TCPListener) async throws -> Void
    ) async throws {
        try await _withTaskExecutor(executor) {
            let socket = try ServerSocket.bootstrap(
                protocolFamily: .inet,
                host: host,
                port: port
            )
            try socket.setNonBlocking()

            try socket.setOption(level: .socket, name: .so_reuseaddr, value: 1)

            // We should switch to an IO executor here
            do {
                try executor.register(
                    selectable: socket,
                    interestedEvent: [.reset]
                ) { eventSet, registrationID in
                    NewSelectorRegistration(
                        interested: eventSet,
                        registrationID: registrationID
                    )
                }
                try socket.listen()

                let listener = try Self.init(socket: socket, executor: executor)
                try await body(listener)
                try executor.deregister(socket: socket)
                try socket.close()
            } catch {
                do {
                    try executor.deregister(socket: socket)
                } catch {
                    try socket.close()
                    throw error
                }
                try socket.close()
                throw error
            }
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(socket: self.socket, executor: self.executor)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let socket: ServerSocket
        private let executor: IOExecutor
        private var finished = false

        init(socket: ServerSocket, executor: IOExecutor) {
            self.socket = socket
            self.executor = executor

        }
        public mutating func next() async throws -> Element? {
            // TODO: At best we would want to use `withTaskExecutorPreference` here but it is currently wrongly marked @Sendable
            guard !finished else {
                return nil
            }

            while true {
                if let result = try self.socket.accept(setNonBlocking: true) {
                    // We probably want to get the next executor out of the pool
                    return TCPConnection(socket: result, executor: self.executor)
                } else {
                    if self.finished {
                        return nil
                    }

                    do {
                        // TODO: Handle cancellation
                        let socket = self.socket
                        let executor = self.executor
                        let shouldContinue = try await withTaskCancellationHandler {
                            let eventSet = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SelectorEventSet, Error>) in
                                do {
                                    try self.executor.reregister(
                                        selectable: self.socket
                                    ) { registration in
                                        registration.interested.insert(.read)
                                        registration.interested.insert(.readEOF)
                                        registration.readContinuation = continuation
                                    }
                                } catch {
                                    continuation.resume(with: .failure(error))
                                }
                            }

                            if eventSet.contains(.reset) {
                                self.finished = true
                                return true
                            }

                            if eventSet.contains(.readEOF) {
                                self.finished = true
                                return true
                            }

                            try self.executor.reregister(selectable: self.socket) { registration in
                                registration.interested.subtract(.read)
                                registration.interested.subtract(.readEOF)
                            }

                            if eventSet.contains(.read) {
                                return true
                            } else {
                                fatalError()
                            }
                        } onCancel: {
                            // TODO: We should introduce some kind of token system here
                            try! executor.deregister(socket: socket)
                        }

                        if shouldContinue {
                            continue
                        } else {
                            return nil
                        }


                    } catch {
                        finished = true
                        throw error
                    }
                }
            }
        }
    }
}
