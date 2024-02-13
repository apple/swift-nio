import NIOPosix
import NIOCore
import XCTest

final class EchoHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    var halfClosureAfterFirstRead = false

    init(halfClosureAfterFirstRead: Bool = false) {
        self.halfClosureAfterFirstRead = halfClosureAfterFirstRead
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.write(data, promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()

        if halfClosureAfterFirstRead {
            context.close(mode: .output, promise: nil)
        }
    }
}

final class TCPTests: XCTestCase {
    static let executor = IOExecutor.make(name: "Test")

    func test() async throws {
        let serverChannel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(EchoHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()

        try await TCPConnection.connect(
            executor: Self.executor,
            target: serverChannel.localAddress!
        ) { inbound, outbound in
            let hello = ByteBuffer(string: "Hello")
            try await outbound.write(hello)
            var iterator = inbound.makeAsyncIterator()
            let response = try await iterator.next()
            XCTAssertEqual(response, hello)
        }
    }

    func testHalfClosure() async throws {
        let serverChannel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(EchoHandler(halfClosureAfterFirstRead: true))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()

        try await TCPConnection.connect(
            executor: Self.executor,
            target: serverChannel.localAddress!
        ) { inbound, outbound in
            let hello = ByteBuffer(string: "Hello")
            try await outbound.write(hello)
            var iterator = inbound.makeAsyncIterator()
            let response1 = try await iterator.next()
            XCTAssertEqual(response1, hello)
            let response2 = try await iterator.next()
            XCTAssertNil(response2)
        }
    }

    func testServerAndClient() async throws {
        try await TCPListener.bind(
            executor: Self.executor,
            host: "127.0.0.1",
            port: 0
        ) { listener in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withThrowingDiscardingTaskGroup { group in
                        print("Waiting for connections")
                        for try await connection in listener {
                            print("Got connection")
                            group.addTask {
                                try! await connection.withInboundOutbound { inbound, outbound in
                                    for try await data in inbound {
                                        try await outbound.write(data)
                                    }
                                }
                            }
                        }
                    }
                }

                try await TCPConnection.connect(
                    executor: Self.executor,
                    target: listener.localAddress
                ) { inbound, outbound in
                    print("Connected to server")
                    let hello = ByteBuffer(string: "Hello")
                    try await outbound.write(hello)
                    var iterator = inbound.makeAsyncIterator()
                    let response = try await iterator.next()
                    XCTAssertEqual(response, hello)
                }

                group.cancelAll()
            }
        }
    }

    func testServerAndClient_sererHalfClosure() async throws {
        try await TCPListener.bind(
            executor: Self.executor,
            host: "127.0.0.1",
            port: 0
        ) { listener in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withThrowingDiscardingTaskGroup { group in
                        for try await connection in listener {
                            group.addTask {
                                try! await connection.withInboundOutbound { inbound, outbound in
                                    var iterator = inbound.makeAsyncIterator()
                                    guard let data = try await iterator.next() else {
                                        return
                                    }
                                    try await outbound.write(data)
                                    try await outbound.finish()
                                }
                            }
                        }
                    }
                }

                try await TCPConnection.connect(
                    executor: Self.executor,
                    target: listener.localAddress
                ) { inbound, outbound in
                    let hello = ByteBuffer(string: "Hello")
                    try await outbound.write(hello)
                    var iterator = inbound.makeAsyncIterator()
                    let response1 = try await iterator.next()
                    XCTAssertEqual(response1, hello)
                    let response2 = try await iterator.next()
                    XCTAssertNil(response2)
                }

                group.cancelAll()
            }
        }
    }

    func testServerAndClient_clientHalfClosure() async throws {
        try await TCPListener.bind(
            executor: Self.executor,
            host: "127.0.0.1",
            port: 0
        ) { listener in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withThrowingDiscardingTaskGroup { group in
                        for try await connection in listener {
                            group.addTask {
                                try! await connection.withInboundOutbound { inbound, outbound in
                                    for try await data in inbound {
                                        try await outbound.write(data)
                                    }
                                }
                            }
                        }
                    }
                }

                try await TCPConnection.connect(
                    executor: Self.executor,
                    target: listener.localAddress
                ) { inbound, outbound in
                    let hello = ByteBuffer(string: "Hello")
                    try await outbound.write(hello)
                    var iterator = inbound.makeAsyncIterator()
                    let response = try await iterator.next()
                    XCTAssertEqual(response, hello)
                    try await outbound.finish()
                }

                group.cancelAll()
            }
        }
    }
}
