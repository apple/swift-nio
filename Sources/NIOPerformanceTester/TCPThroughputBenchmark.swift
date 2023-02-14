import NIOCore
import NIOPosix

/// Test measure a TCP channel throughput.
/// Server send 100K messages to the client,
/// measure the time from the very first message sent by the server
/// to the last message received by the clien.

class TCPThroughputBenchmark: Benchmark {

    private let messages: Int
    private let messageSize: Int

    private var group: EventLoopGroup!
    private var serverChannel: Channel!
    private var serverHandler: ServerHandler!
    private var clientChannel: Channel!

    private var message: ByteBuffer!
    private var isDonePromise: EventLoopPromise<Void>!

    final class ServerHandler: ChannelInboundHandler {
        public typealias InboundIn = ByteBuffer
        public typealias OutboundOut = ByteBuffer

        private var channel: Channel!

        public func channelActive(context: ChannelHandlerContext) {
            self.channel = context.channel
        }

        public func send(_ message: ByteBuffer, times count: Int) {
            for _ in 0..<count {
                _ = self.channel.writeAndFlush(message.slice())
            }
        }
    }

    final class StreamDecoder: ByteToMessageDecoder {
        public typealias InboundIn = ByteBuffer
        public typealias InboundOut = ByteBuffer

        public func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
            if buffer.readableBytes >= MemoryLayout<UInt16>.size {
                let messageSize = buffer.getInteger(at: buffer.readerIndex, as: UInt16.self)!
                if buffer.readableBytes >= messageSize {
                    context.fireChannelRead(self.wrapInboundOut(buffer.readSlice(length: Int(messageSize))!))
                    return .continue
                }
            }
            return .needMoreData
        }
    }

    final class ClientHandler: ChannelInboundHandler {
        public typealias InboundIn = ByteBuffer
        public typealias OutboundOut = ByteBuffer

        private let benchmark: TCPThroughputBenchmark
        private var messagesReceived: Int

        init(_ benchmark: TCPThroughputBenchmark) {
            self.benchmark = benchmark
            self.messagesReceived = 0
        }

        public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            self.messagesReceived += 1
            if (self.benchmark.messages == self.messagesReceived) {
                self.benchmark.isDonePromise.succeed()
                self.messagesReceived = 0
            }
        }
    }

    public init(messages: Int, messageSize: Int) {
        self.messages = messages
        self.messageSize = messageSize
    }

    func setUp() throws {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 4)

        let connectionEstablished: EventLoopPromise<Void> = self.group.next().makePromise()

        self.serverChannel = try ServerBootstrap(group: self.group)
            .childChannelInitializer { channel in
                self.serverHandler = ServerHandler()
                connectionEstablished.succeed()
                return channel.pipeline.addHandler(self.serverHandler)
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()

        self.clientChannel = try ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(ByteToMessageHandler(StreamDecoder())).flatMap { v in
                    channel.pipeline.addHandler(ClientHandler(self))
                }
            }
            .connect(to: serverChannel.localAddress!)
            .wait()

        var message = self.serverChannel.allocator.buffer(capacity: self.messageSize)
        message.writeInteger(UInt16(messageSize), as:UInt16.self)
        for idx in 0..<(self.messageSize - MemoryLayout<UInt16>.stride) {
            message.writeInteger(UInt8(idx%(Int(UInt8.max)+1)), endianness:.little, as:UInt8.self)
        }
        self.message = message

        try connectionEstablished.futureResult.wait()
    }

    func tearDown() {
        try! self.clientChannel.close().wait()
        try! self.serverChannel.close().wait()
        try! self.group.syncShutdownGracefully()
    }

    func run() throws -> Int {
        self.isDonePromise = self.group.next().makePromise()
        Task {
            self.serverHandler.send(self.message, times: self.messages)
        }
        try self.isDonePromise.futureResult.wait()
        self.isDonePromise = nil
        return 0
    }
}
