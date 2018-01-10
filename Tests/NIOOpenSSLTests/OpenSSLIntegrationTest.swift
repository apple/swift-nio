//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
import CNIOOpenSSL
@testable import NIO
@testable import NIOOpenSSL
import NIOTLS
import class Foundation.Process

public func assertNoThrowWithValue<T>(_ body: @autoclosure () throws -> T, defaultValue: T? = nil, file: StaticString = #file, line: UInt = #line) throws -> T {
    do {
        return try body()
    } catch {
        XCTFail("unexpected error \(error) thrown", file: file, line: line)
        if let defaultValue = defaultValue {
            return defaultValue
        } else {
            throw error
        }
    }
}

private func interactInMemory(clientChannel: EmbeddedChannel, serverChannel: EmbeddedChannel) throws {
    var workToDo = true
    while workToDo {
        workToDo = false
        let clientDatum = clientChannel.readOutbound()
        let serverDatum = serverChannel.readOutbound()

        if let clientMsg = clientDatum {
            try serverChannel.writeInbound(data: clientMsg)
            workToDo = true
        }

        if let serverMsg = serverDatum {
            try clientChannel.writeInbound(data: serverMsg)
            workToDo = true
        }
    }
}

private final class SimpleEchoServer: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer
    public typealias InboundUserEventIn = TLSUserEvent
    
    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        ctx.write(data: data, promise: nil)
        ctx.fireChannelRead(data: data)
    }
    
    public func channelReadComplete(ctx: ChannelHandlerContext) {
        ctx.flush(promise: nil)
        ctx.fireChannelReadComplete()
    }
}

internal final class PromiseOnReadHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer
    public typealias InboundUserEventIn = TLSUserEvent
    
    private let promise: EventLoopPromise<ByteBuffer>
    private var data: NIOAny? = nil
    
    init(promise: EventLoopPromise<ByteBuffer>) {
        self.promise = promise
    }
    
    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        self.data = data
        ctx.fireChannelRead(data: data)
    }

    public func channelReadComplete(ctx: ChannelHandlerContext) {
        promise.succeed(result: unwrapInboundIn(data!))
        ctx.fireChannelReadComplete()
    }
}

private final class WriteCountingHandler: ChannelOutboundHandler {
    public typealias OutboundIn = Any
    public typealias OutboundOut = Any

    public var writeCount = 0

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        writeCount += 1
        ctx.write(data: data, promise: promise)
    }
}

public final class EventRecorderHandler<UserEventType>: ChannelInboundHandler where UserEventType: Equatable {
    public typealias InboundIn = ByteBuffer
    public typealias InboundUserEventIn = UserEventType

    public enum RecordedEvents: Equatable {
        case Registered
        case Unregistered
        case Active
        case Inactive
        case Read
        case ReadComplete
        case WritabilityChanged
        case UserEvent(UserEventType)
        // Note that this omits ErrorCaught. This is because Error does not
        // require Equatable, so we can't safely record these events and expect
        // a sensible implementation of Equatable here.

        public static func ==(lhs: RecordedEvents, rhs: RecordedEvents) -> Bool {
            switch (lhs, rhs) {
            case (.Registered, .Registered),
                 (.Unregistered, .Unregistered),
                 (.Active, .Active),
                 (.Inactive, .Inactive),
                 (.Read, .Read),
                 (.ReadComplete, .ReadComplete),
                 (.WritabilityChanged, .WritabilityChanged):
                return true
            case (.UserEvent(let e1), .UserEvent(let e2)):
                return e1 == e2
            default:
                return false
            }
        }
    }

    public var events: [RecordedEvents] = []

    public func channelRegistered(ctx: ChannelHandlerContext) {
        events.append(.Registered)
        ctx.fireChannelRegistered()
    }

    public func channelUnregistered(ctx: ChannelHandlerContext) {
        events.append(.Unregistered)
        ctx.fireChannelUnregistered()
    }

    public func channelActive(ctx: ChannelHandlerContext) {
        events.append(.Active)
        ctx.fireChannelActive()
    }

    public func channelInactive(ctx: ChannelHandlerContext) {
        events.append(.Inactive)
        ctx.fireChannelInactive()
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        events.append(.Read)
        ctx.fireChannelRead(data: data)
    }

    public func channelReadComplete(ctx: ChannelHandlerContext) {
        events.append(.ReadComplete)
        ctx.fireChannelReadComplete()
    }

    public func channelWritabilityChanged(ctx: ChannelHandlerContext) {
        events.append(.WritabilityChanged)
        ctx.fireChannelWritabilityChanged()
    }

    public func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        guard let ourEvent = tryUnwrapInboundUserEventIn(event) else {
            ctx.fireUserInboundEventTriggered(event: event)
            return
        }
        events.append(.UserEvent(ourEvent))
    }
}

private class ChannelActiveWaiter: ChannelInboundHandler {
    public typealias InboundIn = Any
    private var activePromise: EventLoopPromise<Void>

    public init(promise: EventLoopPromise<Void>) {
        activePromise = promise
    }

    public func channelActive(ctx: ChannelHandlerContext) {
        activePromise.succeed(result: ())
    }

    public func waitForChannelActive() throws {
        try activePromise.futureResult.wait()
    }
}

/// A channel handler that delays all writes that it receives. This is useful
/// in tests that want to ensure that writes propagate through the system in order.
///
/// Note that you must call forceFlush to pass all the data through, or your tests will
/// explode.
private class WriteDelayHandler: ChannelOutboundHandler {
    public typealias OutboundIn = Any
    public typealias OutboundOut = Any

    private var writes: [(ChannelHandlerContext, NIOAny, EventLoopPromise<Void>?)] = []

    func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        writes.append((ctx, data, promise))
    }

    func forceFlush() {
        let writes = self.writes
        self.writes = []
        writes.forEach { $0.0.write(data: $0.1, promise: $0.2) }
    }
}

internal func serverTLSChannel(context: NIOOpenSSL.SSLContext,
                               handlers: [ChannelHandler],
                               group: EventLoopGroup,
                               file: StaticString = #file,
                               line: UInt = #line) throws -> Channel {
    return try assertNoThrowWithValue(serverTLSChannel(context: context, preHandlers: [], postHandlers: handlers, group: group), file: file, line: line)
}

internal func serverTLSChannel(context: NIOOpenSSL.SSLContext,
                               preHandlers: [ChannelHandler],
                               postHandlers: [ChannelHandler],
                               group: EventLoopGroup,
                               file: StaticString = #file,
                               line: UInt = #line) throws -> Channel {
    return try assertNoThrowWithValue(ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
        .childChannelInitializer { channel in
            let results = preHandlers.map { channel.pipeline.add(handler: $0) }
            return EventLoopFuture<Void>.andAll(results, eventLoop: results.first?.eventLoop ?? group.next()).then {
                return channel.pipeline.add(handler: try OpenSSLServerHandler(context: context)).then(callback: { v2 in
                    let results = postHandlers.map { channel.pipeline.add(handler: $0) }
                    return EventLoopFuture<Void>.andAll(results, eventLoop: results.first?.eventLoop ?? group.next())
                })
            }
        }.bind(to: "127.0.0.1", on: 0).wait(), file: file, line: line)
}

internal func clientTLSChannel(context: NIOOpenSSL.SSLContext,
                               preHandlers: [ChannelHandler],
                               postHandlers: [ChannelHandler],
                               group: EventLoopGroup,
                               connectingTo: SocketAddress,
                               serverHostname: String? = nil,
                               file: StaticString = #file,
                               line: UInt = #line) throws -> Channel {
    return try assertNoThrowWithValue(ClientBootstrap(group: group)
        .channelInitializer { channel in
            let results = preHandlers.map { channel.pipeline.add(handler: $0) }
            return EventLoopFuture<Void>.andAll(results, eventLoop: results.first?.eventLoop ?? group.next()).then(callback: { v2 in
                return channel.pipeline.add(handler: try OpenSSLClientHandler(context: context, serverHostname: serverHostname)).then(callback: { v2 in
                    let results = postHandlers.map { channel.pipeline.add(handler: $0) }
                    return EventLoopFuture<Void>.andAll(results, eventLoop: results.first?.eventLoop ?? group.next())
                })
            })
        }.connect(to: connectingTo).wait(), file: file, line: line)
}

class OpenSSLIntegrationTest: XCTestCase {
    static var cert: OpenSSLCertificate!
    static var key: OpenSSLPrivateKey!
    
    override class func setUp() {
        super.setUp()
        let (cert, key) = generateSelfSignedCert()
        OpenSSLIntegrationTest.cert = cert
        OpenSSLIntegrationTest.key = key
    }
    
    private func configuredSSLContext(file: StaticString = #file, line: UInt = #line) throws -> NIOOpenSSL.SSLContext {
        let config = TLSConfiguration.forServer(certificateChain: [.certificate(OpenSSLIntegrationTest.cert)],
                                                privateKey: .privateKey(OpenSSLIntegrationTest.key),
                                                trustRoots: .certificates([OpenSSLIntegrationTest.cert]))
        return try assertNoThrowWithValue(SSLContext(configuration: config), file: file, line: line)
    }

    private func configuredClientContext(file: StaticString = #file, line: UInt = #line) throws -> NIOOpenSSL.SSLContext {
        let config = TLSConfiguration.forClient(trustRoots: .certificates([OpenSSLIntegrationTest.cert]))
        return try assertNoThrowWithValue(SSLContext(configuration: config), file: file, line: line)
    }

    func withTrustBundleInFile<T>(tempFile fileName: inout String?, fn: (String) throws -> T) throws -> T {
        fileName = makeTemporaryFile()
        guard let fileName = fileName else {
            fatalError("couldn't make temp file")
        }
        let tempFile = try fileName.withCString { ptr in
            return try Posix.open(file: ptr, oFlag: O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, mode: 0o644)
        }
        precondition(tempFile > 1, String(cString: strerror(errno)))
        let fileBio = BIO_new_fp(fdopen(tempFile, "w+"), BIO_CLOSE)
        precondition(fileBio != nil)

        let rc = PEM_write_bio_X509(fileBio, OpenSSLIntegrationTest.cert.ref)
        BIO_free(fileBio)
        precondition(rc == 1)
        return try fn(fileName)
    }
    
    func testSimpleEcho() throws {
        let ctx = try configuredSSLContext()
        
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        
        let completionPromise: EventLoopPromise<ByteBuffer> = group.next().newPromise()

        let serverChannel: Channel = try serverTLSChannel(context: ctx, handlers: [SimpleEchoServer()], group: group)
        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }
        
        let clientChannel = try clientTLSChannel(context: ctx,
                                                 preHandlers: [],
                                                 postHandlers: [PromiseOnReadHandler(promise: completionPromise)],
                                                 group: group,
                                                 connectingTo: serverChannel.localAddress!)
        defer {
            XCTAssertNoThrow(try clientChannel.close().wait())
        }
        
        var originalBuffer = clientChannel.allocator.buffer(capacity: 5)
        originalBuffer.write(string: "Hello")
        try clientChannel.writeAndFlush(data: NIOAny(originalBuffer)).wait()
        
        let newBuffer = try completionPromise.futureResult.wait()
        XCTAssertEqual(newBuffer, originalBuffer)
    }

    func testHandshakeEventSequencing() throws {
        let ctx = try configuredSSLContext()

        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let readComplete: EventLoopPromise<ByteBuffer> = group.next().newPromise()
        let serverHandler: EventRecorderHandler<TLSUserEvent> = EventRecorderHandler()
        let serverChannel = try serverTLSChannel(context: ctx,
                                                 handlers: [serverHandler, PromiseOnReadHandler(promise: readComplete)],
                                                 group: group)
        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let clientChannel = try clientTLSChannel(context: ctx,
                                                 preHandlers: [],
                                                 postHandlers: [SimpleEchoServer()],
                                                 group: group,
                                                 connectingTo: serverChannel.localAddress!)
        defer {
            XCTAssertNoThrow(try clientChannel.close().wait())
        }

        var originalBuffer = clientChannel.allocator.buffer(capacity: 5)
        originalBuffer.write(string: "Hello")
        try clientChannel.writeAndFlush(data: NIOAny(originalBuffer)).wait()
        _ = try readComplete.futureResult.wait()

        // Ok, the channel is connected and we have written data to it. This means the TLS handshake is
        // done. Check the events.
        // TODO(cory): How do we wait until the read is done? Ideally we'd like to re-use the
        // PromiseOnReadHandler, but we need to get it into the pipeline first. Not sure how yet. Come back to me.
        // Maybe update serverTLSChannel to take an array of channel handlers?
        let expectedEvents: [EventRecorderHandler<TLSUserEvent>.RecordedEvents] = [
            .Registered,
            .Active,
            .UserEvent(TLSUserEvent.handshakeCompleted(negotiatedProtocol: nil)),
            .Read,
            .ReadComplete
        ]

        XCTAssertEqual(expectedEvents, serverHandler.events)
    }

    func testShutdownEventSequencing() throws {
        let ctx = try configuredSSLContext()

        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let readComplete: EventLoopPromise<ByteBuffer> = group.next().newPromise()
        let serverHandler: EventRecorderHandler<TLSUserEvent> = EventRecorderHandler()
        let serverChannel = try serverTLSChannel(context: ctx,
                                                 handlers: [serverHandler, PromiseOnReadHandler(promise: readComplete)],
                                                 group: group)

        let clientChannel = try clientTLSChannel(context: ctx,
                                                 preHandlers: [],
                                                 postHandlers: [SimpleEchoServer()],
                                                 group: group,
                                                 connectingTo: serverChannel.localAddress!)

        var originalBuffer = clientChannel.allocator.buffer(capacity: 5)
        originalBuffer.write(string: "Hello")
        try clientChannel.writeAndFlush(data: NIOAny(originalBuffer)).wait()

        // Ok, we want to wait for the read to finish, then close the server and client connections.
        _ = try readComplete.futureResult.then { _ in
            return serverChannel.close()
        }.then {
            return clientChannel.close()
        }.wait()

        let expectedEvents: [EventRecorderHandler<TLSUserEvent>.RecordedEvents] = [
            .Registered,
            .Active,
            .UserEvent(TLSUserEvent.handshakeCompleted(negotiatedProtocol: nil)),
            .Read,
            .ReadComplete,
            .UserEvent(TLSUserEvent.shutdownCompleted),
            .Inactive,
            .Unregistered
        ]

        XCTAssertEqual(expectedEvents, serverHandler.events)
    }

    func testMultipleClose() throws {
        var serverClosed = false
        let ctx = try configuredSSLContext()

        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let completionPromise: EventLoopPromise<ByteBuffer> = group.next().newPromise()

        let serverChannel = try serverTLSChannel(context: ctx, handlers: [SimpleEchoServer()], group: group)
        defer {
            if !serverClosed {
                XCTAssertNoThrow(try serverChannel.close().wait())
            }
        }

        let clientChannel = try clientTLSChannel(context: ctx,
                                                 preHandlers: [],
                                                 postHandlers: [PromiseOnReadHandler(promise: completionPromise)],
                                                 group: group,
                                                 connectingTo: serverChannel.localAddress!)
        defer {
            XCTAssertNoThrow(try clientChannel.close().wait())
        }

        var originalBuffer = clientChannel.allocator.buffer(capacity: 5)
        originalBuffer.write(string: "Hello")
        try clientChannel.writeAndFlush(data: NIOAny(originalBuffer)).wait()

        let newBuffer = try completionPromise.futureResult.wait()
        XCTAssertEqual(newBuffer, originalBuffer)

        // Ok, the connection is definitely up. Now we want to forcibly call close() on the channel several times with
        // different promises. None of these will fire until clean shutdown happens, but we want to confirm that *all* of them
        // fire.
        //
        // To avoid the risk of the I/O loop actually closing the connection before we're done, we need to hijack the
        // I/O loop and issue all the closes on that thread. Otherwise, the channel will probably pull off the TLS shutdown
        // before we get to the third call to close().
        let promises: [EventLoopPromise<Void>] = [group.next().newPromise(), group.next().newPromise(), group.next().newPromise()]
        group.next().execute {
            for promise in promises {
                serverChannel.close(promise: promise)
            }
        }

        XCTAssertNoThrow(try promises.first!.futureResult.wait())
        serverClosed = true

        for promise in promises {
            XCTAssert(promise.futureResult.fulfilled)
        }
    }

    func testCoalescedWrites() throws {
        let ctx = try configuredSSLContext()

        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let recorderHandler = EventRecorderHandler<TLSUserEvent>()
        let serverChannel = try serverTLSChannel(context: ctx, handlers: [SimpleEchoServer()], group: group)
        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let writeCounter = WriteCountingHandler()
        let readPromise: EventLoopPromise<ByteBuffer> = group.next().newPromise()
        let clientChannel = try clientTLSChannel(context: ctx,
                                                 preHandlers: [writeCounter],
                                                 postHandlers: [PromiseOnReadHandler(promise: readPromise)],
                                                 group: group,
                                                 connectingTo: serverChannel.localAddress!)
        defer {
            XCTAssertNoThrow(try clientChannel.close().wait())
        }

        // We're going to issue a number of small writes. Each of these should be coalesced together
        // such that the underlying layer sees only one write for them. The total number of
        // writes should be (after we flush) 3: one for Client Hello, one for Finished, and one
        // for the coalesced writes.
        var originalBuffer = clientChannel.allocator.buffer(capacity: 1)
        originalBuffer.write(string: "A")
        for _ in 0..<5 {
            clientChannel.write(data: NIOAny(originalBuffer), promise: nil)
        }

        try clientChannel.flush().wait()
        let writeCount = try readPromise.futureResult.then { _ in
            // Here we're in the I/O loop, so we know that no further channel action will happen
            // while we dispatch this callback. This is the perfect time to check how many writes
            // happened.
            return writeCounter.writeCount
        }.wait()
        XCTAssertEqual(writeCount, 3)
    }

    func testCoalescedWritesWithFutures() throws {
        let ctx = try configuredSSLContext()

        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let recorderHandler = EventRecorderHandler<TLSUserEvent>()
        let serverChannel = try serverTLSChannel(context: ctx, handlers: [SimpleEchoServer()], group: group)
        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let clientChannel = try clientTLSChannel(context: ctx,
                                                 preHandlers: [],
                                                 postHandlers: [],
                                                 group: group,
                                                 connectingTo: serverChannel.localAddress!)
        defer {
            XCTAssertNoThrow(try clientChannel.close().wait())
        }

        // We're going to issue a number of small writes. Each of these should be coalesced together
        // and all their futures (along with the one for the flush) should fire, in order, with nothing
        // missed.
        var firedFutures: Array<Int> = []
        var originalBuffer = clientChannel.allocator.buffer(capacity: 1)
        originalBuffer.write(string: "A")
        for index in 0..<5 {
            let promise: EventLoopPromise<Void> = group.next().newPromise()
            promise.futureResult.whenComplete { result in
                switch result {
                case .success:
                    XCTAssertEqual(firedFutures.count, index)
                    firedFutures.append(index)
                case .failure:
                    XCTFail("Write promise failed: \(result)")
                }
            }
            clientChannel.write(data: NIOAny(originalBuffer), promise: promise)
        }

        let flushPromise: EventLoopPromise<Void> = group.next().newPromise()
        flushPromise.futureResult.whenComplete { result in
            switch result {
            case .success:
                XCTAssertEqual(firedFutures, [0, 1, 2, 3, 4])
            case .failure:
                XCTFail("Write promised failed: \(result)")
            }
        }
        clientChannel.flush(promise: flushPromise)

        try flushPromise.futureResult.wait()
    }

    func testImmediateCloseSatisfiesPromises() throws {
        let ctx = try configuredSSLContext()
        let channel = EmbeddedChannel()
        try channel.pipeline.add(handler: OpenSSLClientHandler(context: ctx)).wait()

        // Start by initiating the handshake.
        try channel.connect(to: SocketAddress.unixDomainSocketAddress(path: "/tmp/doesntmatter")).wait()

        // Now call close. This should immediately close, satisfying the promise.
        let closePromise: EventLoopPromise<Void> = channel.eventLoop.newPromise()
        channel.close(promise: closePromise)

        XCTAssertTrue(closePromise.futureResult.fulfilled)
    }

    func testAddingTlsToActiveChannelStillHandshakes() throws {
        let ctx = try configuredSSLContext()
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let recorderHandler: EventRecorderHandler<TLSUserEvent> = EventRecorderHandler()
        let channelActiveWaiter = ChannelActiveWaiter(promise: group.next().newPromise())
        let serverChannel = try serverTLSChannel(context: ctx,
                                                 handlers: [recorderHandler, SimpleEchoServer(), channelActiveWaiter],
                                                 group: group)
        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        // Create a client channel without TLS in it, and connect it.
        let readPromise: EventLoopPromise<ByteBuffer> = group.next().newPromise()
        let promiseOnReadHandler = PromiseOnReadHandler(promise: readPromise)
        let clientChannel = try ClientBootstrap(group: group)
            .channelInitializer({ $0.pipeline.add(handler: promiseOnReadHandler) })
            .connect(to: serverChannel.localAddress!).wait()
        defer {
            XCTAssertNoThrow(try clientChannel.close().wait())
        }

        // Wait until the channel comes up, then confirm that no handshake has been
        // received. This hardly proves much, but it's enough.
        try channelActiveWaiter.waitForChannelActive()
        try group.next().submit {
            XCTAssertEqual(recorderHandler.events, [.Registered, .Active])
        }.wait()

        // Now, add the TLS handler to the pipeline.
        try clientChannel.pipeline.add(name: nil, handler: OpenSSLClientHandler(context: ctx), first: true).wait()
        var data = clientChannel.allocator.buffer(capacity: 1)
        data.write(staticString: "x")
        try clientChannel.writeAndFlush(data: NIOAny(data)).wait()

        // The echo should come back without error.
        _ = try readPromise.futureResult.wait()

        // At this point the handshake should be complete.
        try group.next().submit {
            XCTAssertEqual(recorderHandler.events[..<3], [.Registered, .Active, .UserEvent(.handshakeCompleted(negotiatedProtocol: nil))])
        }.wait()
    }

    func testValidatesHostnameOnConnectionFails() throws {
        let serverCtx = try configuredSSLContext()
        let clientCtx = try configuredClientContext()

        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try? group.syncShutdownGracefully()
        }

        let serverChannel = try serverTLSChannel(context: serverCtx,
                                                 handlers: [],
                                                 group: group)
        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let errorHandler = ErrorCatcher<NIOOpenSSLError>()
        let clientChannel = try clientTLSChannel(context: clientCtx,
                                                 preHandlers: [],
                                                 postHandlers: [errorHandler],
                                                 group: group,
                                                 connectingTo: serverChannel.localAddress!)

        var originalBuffer = clientChannel.allocator.buffer(capacity: 5)
        originalBuffer.write(string: "Hello")
        let writeFuture = clientChannel.writeAndFlush(data: NIOAny(originalBuffer))
        let errorsFuture: EventLoopFuture<[NIOOpenSSLError]> = writeFuture.thenIfError { _ in
            // We're swallowing errors here, on purpose, because we'll definitely
            // hit them.
            return ()
        }.then { _ in
            return errorHandler.errors
        }
        let actualErrors = try errorsFuture.wait()

        // This write will have failed, but that's fine: we just want it as a signal that
        // the handshake is done so we can make our assertions.
        let expectedErrors: [NIOOpenSSLError] = [NIOOpenSSLError.unableToValidateCertificate]

        XCTAssertEqual(expectedErrors, actualErrors)
    }

    func testValidatesHostnameOnConnectionSucceeds() throws {
        let serverCtx = try configuredSSLContext()
        let clientCtx = try configuredClientContext()

        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let serverChannel = try serverTLSChannel(context: serverCtx,
                                                 handlers: [],
                                                 group: group)
        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let eventHandler = EventRecorderHandler<TLSUserEvent>()
        let clientChannel = try clientTLSChannel(context: clientCtx,
                                                 preHandlers: [],
                                                 postHandlers: [eventHandler],
                                                 group: group,
                                                 connectingTo: serverChannel.localAddress!,
                                                 serverHostname: "localhost")

        var originalBuffer = clientChannel.allocator.buffer(capacity: 5)
        originalBuffer.write(string: "Hello")
        let writeFuture = clientChannel.writeAndFlush(data: NIOAny(originalBuffer))
        writeFuture.whenComplete { _ in
            XCTAssertEqual(eventHandler.events[..<3], [.Registered, .Active, .UserEvent(.handshakeCompleted(negotiatedProtocol: nil))])
        }
        try writeFuture.wait()
    }

    func testDontLoseClosePromises() throws {
        let serverChannel = EmbeddedChannel()
        let clientChannel = EmbeddedChannel()

        let ctx = try configuredSSLContext()

        try serverChannel.pipeline.add(handler: try OpenSSLServerHandler(context: ctx)).wait()
        try clientChannel.pipeline.add(handler: try OpenSSLClientHandler(context: ctx)).wait()

        let addr: SocketAddress = try .unixDomainSocketAddress(path: "/tmp/whatever")
        let connectFuture = clientChannel.connect(to: addr)
        serverChannel.pipeline.fireChannelActive()
        try interactInMemory(clientChannel: clientChannel, serverChannel: serverChannel)
        try connectFuture.wait()

        // Ok, we're connected. Good stuff! Now, we want to hit this specific window:
        // 1. Call close() on the server channel. This will transition it to the closing state.
        // 2. Fire channelInactive on the serverChannel. This should cause it to drop all state and
        //    fire the close promise.
        // Because we're using the embedded channel here, we don't need to worry about thread
        // synchronization: all of this should succeed synchronously. If it doesn't, that's
        // a bug too!
        let closePromise = serverChannel.close()
        XCTAssertFalse(closePromise.fulfilled)

        serverChannel.pipeline.fireChannelInactive()
        XCTAssertTrue(closePromise.fulfilled)

        closePromise.whenComplete {
            switch $0 {
            case .failure(OpenSSLError.uncleanShutdown):
                break
            default:
                XCTFail("Unexpected result: \($0)")
            }
        }
    }

    func testTrustStoreOnDisk() throws {
        var tempFile: String? = nil
        let serverCtx = try configuredSSLContext()
        let config = try withTrustBundleInFile(tempFile: &tempFile) {
            return TLSConfiguration.forClient(certificateVerification: .noHostnameVerification,
                                              trustRoots: .file($0),
                                              certificateChain: [.certificate(OpenSSLIntegrationTest.cert)],
                                              privateKey: .privateKey(OpenSSLIntegrationTest.key))
        }
        defer {
            precondition(.some(0) == tempFile.map { unlink($0) }, "couldn't remove temp file \(tempFile.debugDescription)")
        }
        let clientCtx = try assertNoThrowWithValue(SSLContext(configuration: config))

        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let completionPromise: EventLoopPromise<ByteBuffer> = group.next().newPromise()
        let serverChannel: Channel = try serverTLSChannel(context: serverCtx, handlers: [SimpleEchoServer()], group: group)
        defer {
            _ = try? serverChannel.close().wait()
        }

        let clientChannel = try clientTLSChannel(context: clientCtx,
                                                 preHandlers: [],
                                                 postHandlers: [PromiseOnReadHandler(promise: completionPromise)],
                                                 group: group,
                                                 connectingTo: serverChannel.localAddress!)
        defer {
            _ = try? clientChannel.close().wait()
        }

        var originalBuffer = clientChannel.allocator.buffer(capacity: 5)
        originalBuffer.write(string: "Hello")

        try clientChannel.writeAndFlush(data: NIOAny(originalBuffer)).wait()
        let newBuffer = try completionPromise.futureResult.wait()
        XCTAssertEqual(newBuffer, originalBuffer)
    }

    func testChecksTrustStoreOnDisk() throws {
        let serverCtx = try configuredSSLContext()
        let clientConfig = TLSConfiguration.forClient(certificateVerification: .noHostnameVerification,
                                                      trustRoots: .file("/tmp"),
                                                      certificateChain: [.certificate(OpenSSLIntegrationTest.cert)],
                                                      privateKey: .privateKey(OpenSSLIntegrationTest.key))
        let clientCtx = try assertNoThrowWithValue(SSLContext(configuration: clientConfig))

        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let serverChannel = try serverTLSChannel(context: serverCtx,
                                                 handlers: [],
                                                 group: group)
        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let errorHandler = ErrorCatcher<NIOOpenSSLError>()
        let clientChannel = try clientTLSChannel(context: clientCtx,
                                                 preHandlers: [],
                                                 postHandlers: [errorHandler],
                                                 group: group,
                                                 connectingTo: serverChannel.localAddress!)

        var originalBuffer = clientChannel.allocator.buffer(capacity: 5)
        originalBuffer.write(string: "Hello")
        let writeFuture = clientChannel.writeAndFlush(data: NIOAny(originalBuffer))
        let errorsFuture: EventLoopFuture<[NIOOpenSSLError]> = writeFuture.thenIfError { _ in
            // We're swallowing errors here, on purpose, because we'll definitely
            // hit them.
            return ()
            }.then { _ in
                return errorHandler.errors
        }
        let actualErrors = try errorsFuture.wait()

        // The actual error is non-deterministic depending on platform and version, so we don't
        // really try to make too many assertions here.
        XCTAssertEqual(actualErrors.count, 1)
        try clientChannel.closeFuture.wait()
    }

    func testReadAfterCloseNotifyDoesntKillProcess() throws {
        let serverChannel = EmbeddedChannel()
        let clientChannel = EmbeddedChannel()

        let ctx = try configuredSSLContext()

        try serverChannel.pipeline.add(handler: try OpenSSLServerHandler(context: ctx)).wait()
        try clientChannel.pipeline.add(handler: try OpenSSLClientHandler(context: ctx)).wait()

        let addr: SocketAddress = try .unixDomainSocketAddress(path: "/tmp/whatever2")
        let connectFuture = clientChannel.connect(to: addr)
        serverChannel.pipeline.fireChannelActive()
        try interactInMemory(clientChannel: clientChannel, serverChannel: serverChannel)
        try connectFuture.wait()

        // Ok, we're connected. Now we want to close the server, and have that trigger a client CLOSE_NOTIFY.
        // However, when we deliver that CLOSE_NOTIFY we're then going to immediately send another chunk of
        // data. We can get away with doing this because the Embedded channel fires any promise for close()
        // before it fires channelInactive, which will allow us to fire channelRead from within the callback.
        let closePromise = serverChannel.close()
        closePromise.whenComplete { _ in
            var buffer = serverChannel.allocator.buffer(capacity: 5)
            buffer.write(staticString: "hello")
            serverChannel.pipeline.fireChannelRead(data: NIOAny(buffer))
            serverChannel.pipeline.fireChannelReadComplete()
        }

        do {
            try serverChannel.throwIfErrorCaught()
        } catch {
            XCTFail("Already has error: \(error)")
        }

        do {
            try interactInMemory(clientChannel: clientChannel, serverChannel: serverChannel)
            XCTFail("Did not cause error")
        } catch NIOOpenSSLError.readInInvalidTLSState {
            // Nothing to do here.
        } catch {
            XCTFail("Encountered unexpected error: \(error)")
        }
    }

    func testZeroLengthWrite() throws {
        let ctx = try configuredSSLContext()

        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try? group.syncShutdownGracefully()
        }

        let completionPromise: EventLoopPromise<ByteBuffer> = group.next().newPromise()

        let serverChannel = try serverTLSChannel(context: ctx,
                                                 handlers: [PromiseOnReadHandler(promise: completionPromise)],
                                                 group: group)
        defer {
            _ = try? serverChannel.close().wait()
        }

        let clientChannel = try clientTLSChannel(context: ctx,
                                                 preHandlers: [],
                                                 postHandlers: [],
                                                 group: group,
                                                 connectingTo: serverChannel.localAddress!)
        defer {
            _ = try? clientChannel.close().wait()
        }

        // Write several zero-length buffers *and* one with some actual data. Only one should
        // be written.
        var originalBuffer = clientChannel.allocator.buffer(capacity: 5)
        let promises = (0...5).map { _ in clientChannel.write(data: NIOAny(originalBuffer)) }
        originalBuffer.write(staticString: "hello")
        _ = try clientChannel.writeAndFlush(data: NIOAny(originalBuffer)).wait()

        // At this time all the writes should have succeeded.
        XCTAssertTrue(promises.map { $0.fulfilled }.reduce(true, { $0 && $1 }))

        let newBuffer = try completionPromise.futureResult.wait()
        XCTAssertEqual(newBuffer, originalBuffer)
    }

    func testZeroLengthWritePromisesFireInOrder() throws {
        let serverChannel = EmbeddedChannel()
        let clientChannel = EmbeddedChannel()

        let ctx = try configuredSSLContext()

        try serverChannel.pipeline.add(handler: try OpenSSLServerHandler(context: ctx)).wait()
        try clientChannel.pipeline.add(handler: try OpenSSLClientHandler(context: ctx)).wait()

        let addr: SocketAddress = try .unixDomainSocketAddress(path: "/tmp/whatever2")
        let connectFuture = clientChannel.connect(to: addr)
        serverChannel.pipeline.fireChannelActive()
        try interactInMemory(clientChannel: clientChannel, serverChannel: serverChannel)
        try connectFuture.wait()

        // This test fires three writes, flushing between them all. We want to confirm that all of the
        // writes are succeeded in order. To do that, we want to add a WriteDelayHandler to
        // prevent the EmbeddedChannel succeeding the early writes.
        let writeDelayer = WriteDelayHandler()
        try clientChannel.pipeline.add(handler: writeDelayer, first: true).wait()
        var writeCount = 0
        let emptyBuffer = clientChannel.allocator.buffer(capacity: 16)
        var buffer = clientChannel.allocator.buffer(capacity: 16)
        buffer.write(staticString: "hello world")

        clientChannel.write(data: NIOAny(buffer)).whenComplete { _ in
            XCTAssertEqual(writeCount, 0)
            writeCount = 1
        }
        clientChannel.flush(promise: nil)
        clientChannel.write(data: NIOAny(emptyBuffer)).whenComplete { _ in
            XCTAssertEqual(writeCount, 1)
            writeCount = 2
        }
        clientChannel.flush(promise: nil)
        clientChannel.write(data: NIOAny(buffer)).whenComplete { _ in
            XCTAssertEqual(writeCount, 2)
            writeCount = 3
        }
        clientChannel.flush(promise: nil)

        XCTAssertEqual(writeCount, 0)
        writeDelayer.forceFlush()
        XCTAssertEqual(writeCount, 3)
    }
}
