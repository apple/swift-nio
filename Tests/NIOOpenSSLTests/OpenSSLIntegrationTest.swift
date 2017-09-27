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
import OpenSSL
@testable import NIO
@testable import NIOOpenSSL


private final class SimpleEchoServer: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer
    public typealias InboundUserEventIn = TLSUserEvent
    
    public func channelRead(ctx: ChannelHandlerContext, data: IOData) {
        ctx.write(data: data, promise: nil)
    }
    
    public func channelReadComplete(ctx: ChannelHandlerContext) {
        ctx.flush(promise: nil)
    }
}

private final class PromiseOnReadHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer
    public typealias InboundUserEventIn = TLSUserEvent
    
    private let promise: Promise<ByteBuffer>
    private var data: IOData? = nil
    
    init(promise: Promise<ByteBuffer>) {
        self.promise = promise
    }
    
    public func channelRead(ctx: ChannelHandlerContext, data: IOData) {
        self.data = data
    }

    public func channelReadComplete(ctx: ChannelHandlerContext) {
        promise.succeed(result: unwrapInboundIn(data!))
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

    public func channelRead(ctx: ChannelHandlerContext, data: IOData) {
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

private func serverTLSChannel(withContext: NIOOpenSSL.SSLContext, andHandlers: [ChannelHandler], onGroup: EventLoopGroup) throws -> Channel {
    return try ServerBootstrap(group: onGroup)
        .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
        .handler(childHandler: ChannelInitializer(initChannel: { channel in
            return channel.pipeline.add(handler: OpenSSLHandler(context: withContext)).then(callback: { v2 in
                let results = andHandlers.map { channel.pipeline.add(handler: $0) }

                // NB: This assumes that the futures will always fire in order. This is not necessarily guaranteed
                // but in the absence of a way to gather a complete set of Future results, there is no other
                // option.
                return results.last ?? channel.eventLoop.newSucceedFuture(result: ())
            })
        })).bind(to: "127.0.0.1", on: 0).wait()
}

private func clientTLSChannel(withContext: NIOOpenSSL.SSLContext,
                              andHandler: ChannelHandler,
                              onGroup: EventLoopGroup,
                              connectingTo: SocketAddress) throws -> Channel {
    return try ClientBootstrap(group: onGroup)
        .handler(handler: ChannelInitializer(initChannel: { channel in
            return channel.pipeline.add(handler: OpenSSLHandler(context: withContext)).then(callback: { v2 in
                return channel.pipeline.add(handler: andHandler)
            })
        })).connect(to: connectingTo).wait()
}

class OpenSSLIntegrationTest: XCTestCase {
    static var cert: UnsafeMutablePointer<X509>!
    static var key: UnsafeMutablePointer<EVP_PKEY>!
    
    override class func setUp() {
        super.setUp()
        let (cert, key) = generateSelfSignedCert()
        OpenSSLIntegrationTest.cert = cert
        OpenSSLIntegrationTest.key = key
    }
    
    private func configuredSSLContext() throws -> NIOOpenSSL.SSLContext {
        let ctx = SSLContext()!
        try ctx.setLeafCertificate(OpenSSLIntegrationTest.cert)
        try ctx.setPrivateKey(OpenSSLIntegrationTest.key)
        try ctx.addRootCertificate(OpenSSLIntegrationTest.cert)
        return ctx
    }
    
    func testSimpleEcho() throws {
        let ctx = try configuredSSLContext()
        
        let group = try MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
        }
        
        let completionPromise: Promise<ByteBuffer> = group.next().newPromise()

        let serverChannel = try serverTLSChannel(withContext: ctx, andHandlers: [SimpleEchoServer()], onGroup: group)
        defer {
            _ = try! serverChannel.close().wait()
        }
        
        let clientChannel = try clientTLSChannel(withContext: ctx,
                                                 andHandler: PromiseOnReadHandler(promise: completionPromise),
                                                 onGroup: group,
                                                 connectingTo: serverChannel.localAddress!)
        defer {
            _ = try! clientChannel.close().wait()
        }
        
        var originalBuffer = clientChannel.allocator.buffer(capacity: 5)
        originalBuffer.write(string: "Hello")
        try clientChannel.writeAndFlush(data: IOData(originalBuffer)).wait()
        
        let newBuffer = try completionPromise.futureResult.wait()
        XCTAssertEqual(newBuffer, originalBuffer)
    }

    func testHandshakeEventSequencing() throws {
        let ctx = try configuredSSLContext()

        let group = try MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
        }

        let readComplete: Promise<ByteBuffer> = group.next().newPromise()
        let serverHandler: EventRecorderHandler<TLSUserEvent> = EventRecorderHandler()
        let serverChannel = try serverTLSChannel(withContext: ctx,
                                                 andHandlers: [serverHandler, PromiseOnReadHandler(promise: readComplete)],
                                                 onGroup: group)
        defer {
            _ = try! serverChannel.close().wait()
        }

        let clientChannel = try clientTLSChannel(withContext: ctx,
                                                 andHandler: SimpleEchoServer(),
                                                 onGroup: group,
                                                 connectingTo: serverChannel.localAddress!)
        defer {
            _ = try! clientChannel.close().wait()
        }

        var originalBuffer = clientChannel.allocator.buffer(capacity: 5)
        originalBuffer.write(string: "Hello")
        try clientChannel.writeAndFlush(data: IOData(originalBuffer)).wait()
        _ = try readComplete.futureResult.wait()

        // Ok, the channel is connected and we have written data to it. This means the TLS handshake is
        // done. Check the events.
        // TODO(cory): How do we wait until the read is done? Ideally we'd like to re-use the
        // PromiseOnReadHandler, but we need to get it into the pipeline first. Not sure how yet. Come back to me.
        // Maybe update serverTLSChannel to take an array of channel handlers?
        let expectedEvents: [EventRecorderHandler<TLSUserEvent>.RecordedEvents] = [
            .Registered,
            .Active,
            .UserEvent(TLSUserEvent.handshakeCompleted),
            .Read,
            .ReadComplete
        ]

        XCTAssertEqual(expectedEvents, serverHandler.events)
    }

    func testShutdownEventSequencing() throws {
        let ctx = try configuredSSLContext()

        let group = try MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
        }

        let readComplete: Promise<ByteBuffer> = group.next().newPromise()
        let serverHandler: EventRecorderHandler<TLSUserEvent> = EventRecorderHandler()
        let serverChannel = try serverTLSChannel(withContext: ctx,
                                                 andHandlers: [serverHandler, PromiseOnReadHandler(promise: readComplete)],
                                                 onGroup: group)

        let clientChannel = try clientTLSChannel(withContext: ctx,
                                                 andHandler: SimpleEchoServer(),
                                                 onGroup: group,
                                                 connectingTo: serverChannel.localAddress!)

        var originalBuffer = clientChannel.allocator.buffer(capacity: 5)
        originalBuffer.write(string: "Hello")
        try clientChannel.writeAndFlush(data: IOData(originalBuffer)).wait()

        // Ok, we want to wait for the read to finish, then close the server and client connections.
        _ = try readComplete.futureResult.then { _ in
            return serverChannel.close()
        }.then {
            return clientChannel.close()
        }.wait()

        let expectedEvents: [EventRecorderHandler<TLSUserEvent>.RecordedEvents] = [
            .Registered,
            .Active,
            .UserEvent(TLSUserEvent.handshakeCompleted),
            .Read,
            .ReadComplete,
            .UserEvent(TLSUserEvent.cleanShutdown),
            .Inactive,
            .Unregistered
        ]

        XCTAssertEqual(expectedEvents, serverHandler.events)
    }

    func testMultipleClose() throws {
        var serverClosed = false
        let ctx = try configuredSSLContext()

        let group = try MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
        }

        let completionPromise: Promise<ByteBuffer> = group.next().newPromise()

        let serverChannel = try serverTLSChannel(withContext: ctx, andHandlers: [SimpleEchoServer()], onGroup: group)
        defer {
            if !serverClosed {
                _ = try! serverChannel.close().wait()
            }
        }

        let clientChannel = try clientTLSChannel(withContext: ctx,
                                                 andHandler: PromiseOnReadHandler(promise: completionPromise),
                                                 onGroup: group,
                                                 connectingTo: serverChannel.localAddress!)
        defer {
            _ = try! clientChannel.close().wait()
        }

        var originalBuffer = clientChannel.allocator.buffer(capacity: 5)
        originalBuffer.write(string: "Hello")
        try clientChannel.writeAndFlush(data: IOData(originalBuffer)).wait()

        let newBuffer = try completionPromise.futureResult.wait()
        XCTAssertEqual(newBuffer, originalBuffer)

        // Ok, the connection is definitely up. Now we want to forcibly call close() on the channel several times with
        // different promises. None of these will fire until clean shutdown happens, but we want to confirm that *all* of them
        // fire.
        //
        // To avoid the risk of the I/O loop actually closing the connection before we're done, we need to hijack the
        // I/O loop and issue all the closes on that thread. Otherwise, the channel will probably pull off the TLS shutdown
        // before we get to the third call to close().
        let promises: [Promise<Void>] = [group.next().newPromise(), group.next().newPromise(), group.next().newPromise()]
        group.next().execute {
            for promise in promises {
                serverChannel.close(promise: promise)
            }
        }

        _ = try! promises.first!.futureResult.wait()
        serverClosed = true

        for promise in promises {
            XCTAssert(promise.futureResult.fulfilled)
        }
    }
}
