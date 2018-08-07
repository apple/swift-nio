import NIO
import NIOHTTP1

class Client: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    
    var requestURLString: String
    
    init(requestURLString: String) {
        self.requestURLString = requestURLString
    }
    
    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let response = self.unwrapInboundIn(data)
        switch response {
        case .head(let h):
            break
        case .body(let b):
            break
        case .end(let h):
            print("Ending \(requestURLString)")
        }
    }
    
}

var a: Channel

let group = MultiThreadedEventLoopGroup.init(numberOfThreads: 4)
let client = try! ClientBootstrap.init(group: group)
    .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
    .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
    .channelInitializer({ (channel) -> EventLoopFuture<Void> in
        channel.pipeline.addHTTPClientHandlers()
        return channel.pipeline.add(handler: Client(requestURLString: "www.google.com"))
    })
    .connect(host: "www.yahoo.com", port: 80).then { (channel: Channel) -> EventLoopFuture<Void> in
        channel.read()
        channel.write(HTTPClientRequestPart.head(.init(version: .init(major: 1, minor: 1), method: .GET, uri: "www.yahoo.com")))
        
        channel.write(HTTPClientRequestPart.body(.byteBuffer(ByteBufferAllocator.init().buffer(capacity: 0))))
        defer {
            channel.read()
        }
        return channel.writeAndFlush(HTTPClientRequestPart.end(nil))
    }.wait()


try! group.syncShutdownGracefully()
