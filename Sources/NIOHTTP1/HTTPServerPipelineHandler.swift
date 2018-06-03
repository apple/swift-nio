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
//
//  HTTPServerPipelineHandler.swift
//  NIOHTTP1
//
//  Created by Cory Benfield on 01/03/2018.
//

import NIO

/// A utility function that runs the body code only in debug builds, without
/// emitting compiler warnings.
///
/// This is currently the only way to do this in Swift: see
/// https://forums.swift.org/t/support-debug-only-code/11037 for a discussion.
internal func debugOnly(_ body: () -> Void) {
    assert({ body(); return true }())
}

/// A `ChannelHandler` that handles HTTP pipelining by buffering inbound data until a
/// response has been sent.
///
/// This handler ensures that HTTP server pipelines only process one request at a time.
/// This is the safest way for pipelining-unaware code to operate, as it ensures that
/// mutation of any shared server state is not parallelised, and that responses are always
/// sent for each request in turn. In almost all cases this is the behaviour that a
/// pipeline will want. This is achieved without doing too much buffering by preventing
/// the `Channel` from reading from the socket until a complete response is processed,
/// ensuring that a malicious client is not capable of overwhelming a server by shoving
/// an enormous amount of data down the `Channel` while a server is processing a
/// slow response.
///
/// See [RFC 7320 Section 6.3.2](https://tools.ietf.org/html/rfc7230#section-6.3.2) for
/// more details on safely handling HTTP pipelining.
///
/// In addition to handling the request buffering, this `ChannelHandler` is aware of
/// TCP half-close. While there are very few HTTP clients that are capable of TCP
/// half-close, clients that are not HTTP specific (e.g. `netcat`) may trigger a TCP
/// half-close. Having this `ChannelHandler` be aware of TCP half-close makes it easier
/// to build HTTP servers that are resilient to this kind of behaviour.
///
/// The TCP half-close handling is done by buffering the half-close notification along
/// with the HTTP request parts. The half-close notification will be delivered in order
/// with the rest of the reads. If the half-close occurs either before a request is received
/// or during a request body upload, it will be delivered immediately. If a half-close is
/// received immediately after `HTTPServerRequestPart.end`, it will also be passed along
/// immediately, allowing this signal to be seen by the HTTP server as early as possible.
public final class HTTPServerPipelineHandler: ChannelDuplexHandler {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias InboundOut = HTTPServerRequestPart
    public typealias OutboundIn = HTTPServerResponsePart
    public typealias OutboundOut = HTTPServerResponsePart

    public init() {
        debugOnly {
            self.nextExpectedInboundMessage = .head
            self.nextExpectedOutboundMessage = .head
        }
    }

    /// The state of the HTTP connection.
    private enum ConnectionState {
        /// We are waiting for a HTTP response to complete before we
        /// let the next request in.
        case responseEndPending

        /// We are in the middle of both a request and a response and waiting for both `.end`s.
        case requestAndResponseEndPending

        /// Nothing is active on this connection, the next message we expect would be a request `.head`.
        case idle

        /// The server has responded early, before the request has completed. We need
        /// to wait for the request to complete, but won't block anything.
        case requestEndPending

        mutating func requestHeadReceived() {
            switch self {
            case .idle:
                self = .requestAndResponseEndPending
            case .requestAndResponseEndPending, .responseEndPending, .requestEndPending:
                preconditionFailure("received request head in state \(self)")
            }
        }

        mutating func responseEndReceived() {
            switch self {
            case .responseEndPending:
                // Got the response we were waiting for.
                self = .idle
            case .requestAndResponseEndPending:
                // We got a response while still receiving a request, which we have to
                // wait for.
                self = .requestEndPending
            case .requestEndPending, .idle:
                preconditionFailure("Unexpectedly received a response in state \(self)")
            }
        }

        mutating func requestEndReceived() {
            switch self {
            case .requestEndPending:
                // Got the request end we were waiting for.
                self = .idle
            case .requestAndResponseEndPending:
                // We got a request and the response isn't done, wait for the
                // response.
                self = .responseEndPending
            case .responseEndPending, .idle:
                preconditionFailure("Received second request")
            }
        }
    }

    /// The events that this handler buffers while waiting for the server to
    /// generate a response.
    private enum BufferedEvent {
        /// A channelRead event.
        case channelRead(NIOAny)

        case error(HTTPParserError)

        /// A TCP half-close. This is buffered to ensure that subsequent channel
        /// handlers that are aware of TCP half-close are informed about it in
        /// the appropriate order.
        case halfClose
    }

    /// The connection state
    private var state = ConnectionState.idle

    /// While we're waiting to send the response we don't read from the socket.
    /// This keeps track of whether we need to call read() when we've send our response.
    private var readPending = false

    /// The buffered HTTP requests that are not going to be addressed yet. In general clients
    /// don't pipeline, so this initially allocates no space for data at all. Clients that
    /// do pipeline will cause dynamic resizing of the buffer, which is generally acceptable.
    private var eventBuffer = CircularBuffer<BufferedEvent>(initialRingCapacity: 0)

    enum NextExpectedMessageType {
        case head
        case bodyOrEnd
    }

    enum LifecycleState {
        /// Operating normally, accepting all events.
        case acceptingEvents

        /// Quiescing but we're still waiting for the request's `.end` which means we still need to process input.
        case quiescingWaitingForRequestEnd

        /// Quiescing and the last request's `.end` has been seen which means we no longer accept any input.
        case quiescingLastRequestEndReceived
    }

    private var lifecycleState: LifecycleState = .acceptingEvents

    // always `nil` in release builds, never `nil` in debug builds
    private var nextExpectedInboundMessage: NextExpectedMessageType?
    // always `nil` in release builds, never `nil` in debug builds
    private var nextExpectedOutboundMessage: NextExpectedMessageType?

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        guard self.lifecycleState != .quiescingLastRequestEndReceived else {
            return
        }

        if self.eventBuffer.count != 0 || self.state == .responseEndPending {
            self.eventBuffer.append(.channelRead(data))
            return
        } else {
            self.deliverOneMessage(ctx: ctx, data: data)
        }
    }

    private func deliverOneMessage(ctx: ChannelHandlerContext, data: NIOAny) {
        assert(self.lifecycleState != .quiescingLastRequestEndReceived,
               "deliverOneMessage called in lifecycle illegal state \(self.lifecycleState)")
        let msg = self.unwrapInboundIn(data)

        debugOnly {
            switch msg {
            case .head:
                assert(self.nextExpectedInboundMessage == .head)
                self.nextExpectedInboundMessage = .bodyOrEnd
            case .body:
                assert(self.nextExpectedInboundMessage == .bodyOrEnd)
            case .end:
                assert(self.nextExpectedInboundMessage == .bodyOrEnd)
                self.nextExpectedInboundMessage = .head
            }
        }

        switch msg {
        case .head:
            self.state.requestHeadReceived()
        case .end:
            // New request is complete. We don't want any more data from now on.
            self.state.requestEndReceived()

            if self.lifecycleState == .quiescingWaitingForRequestEnd {
                self.lifecycleState = .quiescingLastRequestEndReceived
                self.eventBuffer.removeAll()
            }
            if self.lifecycleState == .quiescingLastRequestEndReceived && self.state == .idle {
                ctx.close(promise: nil)
            }
        case .body:
            ()
        }

        ctx.fireChannelRead(data)
    }

    private func deliverOneError(ctx: ChannelHandlerContext, error: Error) {
        // there is one interesting case in this error sending logic: If we receive a `HTTPParserError` and we haven't
        // received a full request nor the beginning of a response we should treat this as a full request. The reason
        // is that what the user will probably do is send a `.badRequest` response and we should be in a state which
        // allows that.
        if (self.state == .idle || self.state == .requestEndPending) && error is HTTPParserError {
            self.state = .responseEndPending
        }
        ctx.fireErrorCaught(error)
    }

    public func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelShouldQuiesceEvent:
            assert(self.lifecycleState == .acceptingEvents,
                   "unexpected lifecycle state when receiving ChannelShouldQuiesceEvent: \(self.lifecycleState)")
            switch self.state {
            case .responseEndPending:
                // we're not in the middle of a request, let's just shut the door
                self.lifecycleState = .quiescingLastRequestEndReceived
                self.eventBuffer.removeAll()
            case .idle:
                // we're completely idle, let's just close
                self.lifecycleState = .quiescingLastRequestEndReceived
                self.eventBuffer.removeAll()
                ctx.close(promise: nil)
            case .requestEndPending, .requestAndResponseEndPending:
                // we're in the middle of a request, we'll need to keep accepting events until we see the .end
                self.lifecycleState = .quiescingWaitingForRequestEnd
            }
        case ChannelEvent.inputClosed:
            // We only buffer half-close if there are request parts we're waiting to send.
            // Otherwise we deliver the half-close immediately.
            if case .responseEndPending = self.state, self.eventBuffer.count > 0 {
                self.eventBuffer.append(.halfClose)
            } else {
                ctx.fireUserInboundEventTriggered(event)
            }
        default:
            ctx.fireUserInboundEventTriggered(event)
        }
    }

    public func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        guard let httpError = error as? HTTPParserError else {
            self.deliverOneError(ctx: ctx, error: error)
            return
        }
        if case .responseEndPending = self.state {
            self.eventBuffer.append(.error(httpError))
            return
        }
        self.deliverOneError(ctx: ctx, error: error)
    }

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        assert(self.state != .requestEndPending,
               "Received second response while waiting for first one to complete")
        debugOnly {
            let res = self.unwrapOutboundIn(data)
            switch res {
            case .head:
                assert(self.nextExpectedOutboundMessage == .head)
                self.nextExpectedOutboundMessage = .bodyOrEnd
            case .body:
                assert(self.nextExpectedOutboundMessage == .bodyOrEnd)
            case .end:
                assert(self.nextExpectedOutboundMessage == .bodyOrEnd)
                self.nextExpectedOutboundMessage = .head
            }
        }

        var startReadingAgain = false

        switch self.unwrapOutboundIn(data) {
        case .head(var head) where self.lifecycleState != .acceptingEvents:
            if head.isKeepAlive {
                head.headers.replaceOrAdd(name: "connection", value: "close")
            }
            ctx.write(self.wrapOutboundOut(.head(head)), promise: promise)
        case .end:
            startReadingAgain = true

            switch self.lifecycleState {
            case .quiescingWaitingForRequestEnd where self.state == .responseEndPending:
                // we just received the .end that we're missing so we can fall through to closing the connection
                fallthrough
            case .quiescingLastRequestEndReceived:
                ctx.write(data).then {
                    ctx.close()
                }.cascade(promise: promise ?? ctx.channel.eventLoop.newPromise())
            case .acceptingEvents, .quiescingWaitingForRequestEnd:
                ctx.write(data, promise: promise)
            }
        case .body, .head:
            ctx.write(data, promise: promise)
        }

        if startReadingAgain {
            self.state.responseEndReceived()
            self.deliverPendingRequests(ctx: ctx)
            self.startReading(ctx: ctx)
        }
    }

    public func read(ctx: ChannelHandlerContext) {
        if self.lifecycleState != .quiescingLastRequestEndReceived {
            if case .responseEndPending = self.state {
                self.readPending = true
            } else {
                ctx.read()
            }
        }
    }

    /// A response has been sent: we can now start passing reads through
    /// again if there are no further pending requests, and send any read()
    /// call we may have swallowed.
    private func startReading(ctx: ChannelHandlerContext) {
        if self.readPending && self.state != .responseEndPending && self.lifecycleState != .quiescingLastRequestEndReceived {
            self.readPending = false
            ctx.read()
        }
    }

    /// A response has been sent: deliver all pending requests and
    /// mark the channel ready to handle more requests.
    private func deliverPendingRequests(ctx: ChannelHandlerContext) {
        var deliveredRead = false

        while self.state != .responseEndPending, let event = self.eventBuffer.first {
            _ = self.eventBuffer.removeFirst()

            switch event {
            case .channelRead(let read):
                self.deliverOneMessage(ctx: ctx, data: read)
                deliveredRead = true
            case .error(let error):
                ctx.fireErrorCaught(error)
            case .halfClose:
                // When we fire the half-close, we want to forget all prior reads.
                // They will just trigger further half-close notifications we don't
                // need.
                self.readPending = false
                ctx.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
            }
        }

        if deliveredRead {
            ctx.fireChannelReadComplete()
        }

        // We need to quickly check whether there is an EOF waiting here, because
        // if there is we should also unbuffer it and pass it along. There is no
        // advantage in sitting on it, and it may help the later channel handlers
        // be more sensible about keep-alive logic if they can see this early.
        // This is done after `fireChannelReadComplete` to keep the same observable
        // behaviour as `SocketChannel`, which fires these events in this order.
        if case .some(.halfClose) = self.eventBuffer.first {
            _ = self.eventBuffer.removeFirst()
            self.readPending = false
            ctx.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        }
    }
}
