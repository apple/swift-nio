import NIOCore

/// A struct representing a TCP connection.
public struct TCPConnection {
    /// Connects to the target.
    public static func connect(
        executor: IOExecutor,
        target: SocketAddress, // TODO: We want to introduce a target concept here
        _ body: (Inbound, inout Outbound) async throws -> Void
    ) async throws {
        try await _withTaskExecutor(executor) {
            let socket = try Socket(
                protocolFamily: target.protocol,
                type: .stream,
                protocolSubtype: .default,
                setNonBlocking: true
            )

            let inbound = Inbound(socket: socket, executor: executor)
            var outbound = Outbound(socket: socket, executor: executor)

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

                if !(try socket.connect(to: target)) {
                    // We are not connected right away so we have to wait until we become writable
                    let eventSet = try await withCheckedThrowingContinuation { continuation in
                        do {
                            try executor.reregister(
                                selectable: socket
                            ) { registration in
                                registration.interested.insert(.write)
                                registration.interested.insert(.writeEOF)
                                registration.writeContinuation = continuation
                            }
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }

                    // We became writable and can now finish connecting
                    try executor.reregister(selectable: socket) { registration in
                        registration.interested.subtract(.write)
                    }

                    assert(eventSet.contains(.write))
                    try socket.finishConnect()
                }
                try await body(inbound, &outbound)
                // TODO: This needs better handling
                try executor.deregister(socket: socket)
                try socket.close()
            } catch {
                try executor.deregister(socket: socket)
                try socket.close()
                throw error
            }
        }
    }

    private let socket: Socket
    private let executor: IOExecutor

    internal init(socket: Socket, executor: IOExecutor) {
        self.socket = socket
        self.executor = executor
    }

    public func withInboundOutbound(
        _ body: (Inbound, inout Outbound) async throws -> Void
    ) async throws {
        let inbound = Inbound(socket: self.socket, executor: self.executor)
        var outbound = Outbound(socket: self.socket, executor: self.executor)

        try await _withTaskExecutor(self.executor) {
            do {
                try executor.register(
                    selectable: self.socket,
                    interestedEvent: [.reset]
                ) { eventSet, registrationID in
                    NewSelectorRegistration(
                        interested: eventSet,
                        registrationID: registrationID
                    )
                }
                try await body(inbound, &outbound)
                try executor.deregister(socket: socket)
                try socket.close()
            } catch {
                try executor.deregister(socket: socket)
                try socket.close()
                throw error
            }
        }
    }

    public struct Inbound: AsyncSequence {
        public typealias Element = ByteBuffer
        private let asyncSocketSequence: AsyncSocketSequence

        internal init(socket: Socket, executor: IOExecutor) {
            self.asyncSocketSequence = .init(socket: socket, executor: executor)
        }

        public func makeAsyncIterator() -> AsyncIterator {
            return AsyncIterator(iterator: self.asyncSocketSequence.makeAsyncIterator())
        }

        public struct AsyncIterator: AsyncIteratorProtocol {
            private var iterator: AsyncSocketSequence.AsyncIterator

            init(iterator: AsyncSocketSequence.AsyncIterator) {
                self.iterator = iterator
            }

            public mutating func next() async throws -> Element? {
                try await self.iterator.next()
            }
        }
    }

    public struct Outbound: AsyncWriter {
        private let socket: Socket
        private let executor: IOExecutor

        internal init(socket: Socket, executor: IOExecutor) {
            self.socket = socket
            self.executor = executor
        }

        public mutating func write(_ element: consuming ByteBuffer) async throws {
            self.executor.preconditionOnExecutor()
            while true {
                do {
                    let result = try element.withUnsafeReadableBytes {
                        try self.socket.write(pointer: $0)
                    }

                    switch result {
                    case .wouldBlock(let writtenBytes):
                        assert(writtenBytes == 0)
                        try await withCheckedThrowingContinuation { continuation in
                            do {
                                try self.executor.reregister(
                                    selectable: self.socket
                                ) { registration in
                                    registration.interested.insert(.write)
                                    registration.writeContinuation = continuation
                                }
                            } catch {
                                continuation.resume(with: .failure(error))
                            }
                        }

                        try self.executor.reregister(selectable: self.socket) { registration in
                            registration.interested.subtract(.write)
                        }

                    case .processed(let writtenBytes):
                        element.moveReaderIndex(forwardBy: writtenBytes)
                        if element.readableBytes == 0 {
                            return
                        } else {
                            continue
                        }
                    }
                } catch {
                    throw error
                }
            }
        }

        public func finish() async throws {
            self.executor.preconditionOnExecutor()
            try self.socket.shutdown(how: .WR)
        }
    }
}
