//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIOCore

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
public final class HTTPServerPipelineHandler: ChannelDuplexHandler, RemovableChannelHandler {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias InboundOut = HTTPServerRequestPart
    public typealias OutboundIn = HTTPServerResponsePart
    public typealias OutboundOut = HTTPServerResponsePart

    public init() {
        self.nextExpectedInboundMessage = nil
        self.nextExpectedOutboundMessage = nil

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
    private var eventBuffer = CircularBuffer<BufferedEvent>(initialCapacity: 0)

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

        /// Quiescing and we have issued a channel close. Further I/O here is not expected, and won't be managed.
        case quiescingCompleted
    }

    private var lifecycleState: LifecycleState = .acceptingEvents

    // always `nil` in release builds, never `nil` in debug builds
    private var nextExpectedInboundMessage: Optional<NextExpectedMessageType>
    // always `nil` in release builds, never `nil` in debug builds
    private var nextExpectedOutboundMessage: Optional<NextExpectedMessageType>

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.lifecycleState {
        case .quiescingLastRequestEndReceived, .quiescingCompleted:
            // We're done, no more data for you.
            return
        case .acceptingEvents, .quiescingWaitingForRequestEnd:
            // Still accepting I/O
            ()
        }

        if self.eventBuffer.count != 0 || self.state == .responseEndPending {
            self.eventBuffer.append(.channelRead(data))
            return
        } else {
            self.deliverOneMessage(context: context, data: data)
        }
    }

    private func deliverOneMessage(context: ChannelHandlerContext, data: NIOAny) {
        assert(self.lifecycleState != .quiescingLastRequestEndReceived &&
               self.lifecycleState != .quiescingCompleted,
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
                self.lifecycleState = .quiescingCompleted
                context.close(promise: nil)
            }
        case .body:
            ()
        }

        context.fireChannelRead(data)
    }

    private func deliverOneError(context: ChannelHandlerContext, error: Error) {
        // there is one interesting case in this error sending logic: If we receive a `HTTPParserError` and we haven't
        // received a full request nor the beginning of a response we should treat this as a full request. The reason
        // is that what the user will probably do is send a `.badRequest` response and we should be in a state which
        // allows that.
        if (self.state == .idle || self.state == .requestEndPending) && error is HTTPParserError {
            self.state = .responseEndPending
        }
        context.fireErrorCaught(error)
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
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
                self.lifecycleState = .quiescingCompleted
                self.eventBuffer.removeAll()
                context.close(promise: nil)
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
                context.fireUserInboundEventTriggered(event)
            }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard let httpError = error as? HTTPParserError else {
            self.deliverOneError(context: context, error: error)
            return
        }
        if case .responseEndPending = self.state {
            self.eventBuffer.append(.error(httpError))
            return
        }
        self.deliverOneError(context: context, error: error)
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        assert(self.state != .requestEndPending,
               "Received second response while waiting for first one to complete")
        debugOnly {
            let res = self.unwrapOutboundIn(data)
            switch res {
            case .head(let head) where head.isInformational:
                assert(self.nextExpectedOutboundMessage == .head)
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
            context.write(self.wrapOutboundOut(.head(head)), promise: promise)
        case .end:
            startReadingAgain = true

            switch self.lifecycleState {
            case .quiescingWaitingForRequestEnd where self.state == .responseEndPending:
                // we just received the .end that we're missing so we can fall through to closing the connection
                fallthrough
            case .quiescingLastRequestEndReceived:
                self.lifecycleState = .quiescingCompleted
                context.write(data).flatMap {
                    context.close()
                }.cascade(to: promise)
            case .acceptingEvents, .quiescingWaitingForRequestEnd:
                context.write(data, promise: promise)
            case .quiescingCompleted:
                // Uh, why are we writing more data here? We'll write it, but it should be guaranteed
                // to fail.
                assertionFailure("Wrote in quiescing completed state")
                context.write(data, promise: promise)
            }
        case .body, .head:
            context.write(data, promise: promise)
        }

        if startReadingAgain {
            self.state.responseEndReceived()
            self.deliverPendingRequests(context: context)
            self.startReading(context: context)
        }
    }

    public func read(context: ChannelHandlerContext) {
        switch self.lifecycleState {
        case .quiescingLastRequestEndReceived, .quiescingCompleted:
            // We swallow all reads now, as we're going to close the connection.
            ()
        case .acceptingEvents, .quiescingWaitingForRequestEnd:
            if case .responseEndPending = self.state {
                self.readPending = true
            } else {
                context.read()
            }
        }
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        // We're being removed from the pipeline. We need to do a few things:
        //
        // 1. If we have buffered events, deliver them. While we shouldn't be
        //     re-entrantly called, we want to ensure that so we take a local copy.
        // 2. If we are quiescing, we swallowed a quiescing event from the user: replay it,
        //     as the user has hopefully added a handler that will do something with this.
        // 3. Finally, if we have a read pending, we need to release it.
        //
        // The basic theory here is that if there is anything we were going to do when we received
        // either a request .end or a response .end, we do it now because there is no future for us.
        // We also need to ensure we do not drop any data on the floor.
        //
        // At this stage we are no longer in the pipeline, so all further content should be
        // blocked from reaching us. Thus we can avoid mutating our own internal state any
        // longer.
        let bufferedEvents = self.eventBuffer
        for event in bufferedEvents {
            switch event {
            case .channelRead(let read):
                context.fireChannelRead(read)
            case .halfClose:
                context.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
            case .error(let error):
                context.fireErrorCaught(error)
            }
        }


        switch self.lifecycleState {
        case .quiescingLastRequestEndReceived, .quiescingWaitingForRequestEnd:
            context.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        case .acceptingEvents, .quiescingCompleted:
            // Either we haven't quiesced, or we succeeded in doing it.
            ()
        }

        if self.readPending {
            context.read()
        }
    }

    public func channelInactive(context: ChannelHandlerContext) {
        // Welp, this channel isn't going to work anymore. We may as well drop our pending events here, as we
        // cannot be expected to act on them any longer.
        //
        // Side note: it's important that we drop these. If we don't, handlerRemoved will deliver them all.
        // While it's fair to immediately pipeline a channel where the user chose to remove the HTTPPipelineHandler,
        // it's deeply unfair to do so to a user that didn't choose to do that, where it happened to them only because
        // the channel closed.
        //
        // We set keepingCapacity to avoid this reallocating a buffer, as we'll just free it shortly anyway.
        self.eventBuffer.removeAll(keepingCapacity: true)
        context.fireChannelInactive()
    }

    /// A response has been sent: we can now start passing reads through
    /// again if there are no further pending requests, and send any read()
    /// call we may have swallowed.
    private func startReading(context: ChannelHandlerContext) {
        if self.readPending && self.state != .responseEndPending {
            switch self.lifecycleState {
            case .quiescingLastRequestEndReceived, .quiescingCompleted:
                // No more reads in these states.
                ()
            case .acceptingEvents, .quiescingWaitingForRequestEnd:
                self.readPending = false
                context.read()
            }
        }
    }

    /// A response has been sent: deliver all pending requests and
    /// mark the channel ready to handle more requests.
    private func deliverPendingRequests(context: ChannelHandlerContext) {
        var deliveredRead = false

        while self.state != .responseEndPending, let event = self.eventBuffer.first {
            self.eventBuffer.removeFirst()

            switch event {
            case .channelRead(let read):
                self.deliverOneMessage(context: context, data: read)
                deliveredRead = true
            case .error(let error):
                self.deliverOneError(context: context, error: error)
            case .halfClose:
                // When we fire the half-close, we want to forget all prior reads.
                // They will just trigger further half-close notifications we don't
                // need.
                self.readPending = false
                context.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
            }
        }

        if deliveredRead {
            context.fireChannelReadComplete()
        }

        // We need to quickly check whether there is an EOF waiting here, because
        // if there is we should also unbuffer it and pass it along. There is no
        // advantage in sitting on it, and it may help the later channel handlers
        // be more sensible about keep-alive logic if they can see this early.
        // This is done after `fireChannelReadComplete` to keep the same observable
        // behaviour as `SocketChannel`, which fires these events in this order.
        if case .some(.halfClose) = self.eventBuffer.first {
            self.eventBuffer.removeFirst()
            self.readPending = false
            context.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        }
    }
}
