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

/// Triple of
///
///  - the `KeyPath` to the head of the linked list
///  - the `KeyPath` to the `next` pointer
///  - the `KeyPath` to the `prev` pointer
private typealias ChannelPipelineListKeyPathTriple = (ReferenceWritableKeyPath<ChannelPipeline, ChannelHandlerContext?>,
    /*                                             */ ReferenceWritableKeyPath<ChannelHandlerContext, ChannelHandlerContext?>,
    /*                                             */ ReferenceWritableKeyPath<ChannelHandlerContext, ChannelHandlerContext?>)
/* global cache of all the possible key path triples */
private var linkedListKeyPaths: [[ChannelPipelineListKeyPathTriple]] = {
    (0..<8).map { x in
        return (x & 1 != 0, x & 2 != 0, x & 4 != 0)
    }.map { x in
        ChannelPipeline.keyPaths(fromHead: x.0, includeInbound: x.1, includeOutbound: x.2)
    }
}()

/// "A list of `ChannelHandler`s that handle or intercept inbound events and outbound operations of a
/// `Channel`. `ChannelPipeline` implements an advanced form of the Intercepting Filter pattern
/// to give a user full control over how an event is handled and how the `ChannelHandler`s in a pipeline
/// interact with each other.
///
/// # Creation of a pipeline
///
/// Each `Channel` has its own `ChannelPipeline` and it is created automatically when a new `Channel` is created.
///
/// # How an event flows in a pipeline
///
/// The following diagram describes how I/O events are typically processed by `ChannelHandler`s in a `ChannelPipeline`.
/// An I/O event is handled by either a `ChannelInboundHandler` or a `ChannelOutboundHandler`
/// and is forwarded to the next handler in the `ChannelPipeline` by calling the event propagation methods defined in
/// `ChannelHandlerContext`, such as `ChannelHandlerContext.fireChannelRead` and
/// `ChannelHandlerContext.write`.
///
/// ```
///                                                    I/O Request
///                                                    via `Channel` or
///                                                    `ChannelHandlerContext`
///                                                      |
///  +---------------------------------------------------+---------------+
///  |                           ChannelPipeline         |               |
///  |                                TAIL              \|/              |
///  |    +---------------------+            +-----------+----------+    |
///  |    | Inbound Handler  N  |            | Outbound Handler  1  |    |
///  |    +----------+----------+            +-----------+----------+    |
///  |              /|\                                  |               |
///  |               |                                  \|/              |
///  |    +----------+----------+            +-----------+----------+    |
///  |    | Inbound Handler N-1 |            | Outbound Handler  2  |    |
///  |    +----------+----------+            +-----------+----------+    |
///  |              /|\                                  .               |
///  |               .                                   .               |
///  | ChannelHandlerContext.fireIN_EVT() ChannelHandlerContext.OUT_EVT()|
///  |        [ method call]                       [method call]         |
///  |               .                                   .               |
///  |               .                                  \|/              |
///  |    +----------+----------+            +-----------+----------+    |
///  |    | Inbound Handler  2  |            | Outbound Handler M-1 |    |
///  |    +----------+----------+            +-----------+----------+    |
///  |              /|\                                  |               |
///  |               |                                  \|/              |
///  |    +----------+----------+            +-----------+----------+    |
///  |    | Inbound Handler  1  |            | Outbound Handler  M  |    |
///  |    +----------+----------+            +-----------+----------+    |
///  |              /|\             HEAD                 |               |
///  +---------------+-----------------------------------+---------------+
///                  |                                  \|/
///  +---------------+-----------------------------------+---------------+
///  |               |                                   |               |
///  |       [ Socket.read ]                    [ Socket.write ]         |
///  |                                                                   |
///  |  SwiftNIO Internal I/O Threads (Transport Implementation)           |
///  +-------------------------------------------------------------------+
/// ```
///
/// An inbound event is handled by the inbound handlers in the head-to-tail direction as shown on the left side of the
/// diagram. An inbound handler usually handles the inbound data generated by the I/O thread on the bottom of the
/// diagram. The inbound data is often read from a remote peer via the actual input operation such as
/// `Socket.read`. If an inbound event goes beyond the tail inbound handler, it is discarded
/// silently, or logged if it needs your attention.
///
/// An outbound event is handled by the outbound handlers in the tail-to-head direction as shown on the right side of the
/// diagram. An outbound handler usually generates or transforms the outbound traffic such as write requests.
/// If an outbound event goes beyond the head outbound handler, it is handled by an I/O thread associated with the
/// `Channel`. The I/O thread often performs the actual output operation such as `Socket.write`.
///
///
/// For example, let us assume that we created the following pipeline:
///
/// ```
/// ChannelPipeline p = ...;
/// let future = p.add(name: "1", handler: InboundHandlerA()).then(callback: { _ in
///   return p.add(name: "2", handler: InboundHandlerB())
/// }).then(callback: { _ in
///   return p.add(name: "3", handler: OutboundHandlerA())
/// }).then(callback: { _ in
///   p.add(name: "4", handler: OutboundHandlerB())
/// }).then(callback: { _ in
///   p.add(name: "5", handler: InboundOutboundHandlerX())
/// }
/// // Handle the future as well ....
/// ```
///
/// In the example above, a class whose name starts with `Inbound` is an inbound handler.
/// A class whose name starts with `Outbound` is an outbound handler.
///
/// In the given example configuration, the handler evaluation order is 1, 2, 3, 4, 5 when an event goes inbound.
/// When an event goes outbound, the order is 5, 4, 3, 2, 1.  On top of this principle, `ChannelPipeline` skips
/// the evaluation of certain handlers to shorten the stack depth:
///
/// - 3 and 4 don't implement `ChannelInboundHandler`, and therefore the actual evaluation order of an inbound event will be: 1, 2, and 5.
/// - 1 and 2 don't implement `ChannelOutboundHandler`, and therefore the actual evaluation order of a outbound event will be: 5, 4, and 3.
/// - If 5 implements both `ChannelInboundHandler` and `ChannelOutboundHandler`, the evaluation order of an inbound and a outbound event could be 125 and 543 respectively.
///
///
/// # Forwarding an event to the next handler
///
/// As you might noticed in the diagram above, a handler has to invoke the event propagation methods in
/// `ChannelHandlerContext` to forward an event to its next handler.
/// Those methods include:
///
/// - Inbound event propagation methods defined in `ChannelInboundInvoker`
/// - Outbound event propagation methods defined in `ChannelOutboundInvoker`.
///
/// # Building a pipeline
///
/// A user is supposed to have one or more `ChannelHandler`s in a `ChannelPipeline` to receive I/O events (e.g. read) and
/// to request I/O operations (e.g. write and close).  For example, a typical server will have the following handlers
/// in each channel's pipeline, but your mileage may vary depending on the complexity and characteristics of the
/// protocol and business logic:
///
/// - Protocol Decoder - translates binary data (e.g. `ByteBuffer`) into a struct / class
/// - Protocol Encoder - translates a struct / class into binary data (e.g. `ByteBuffer`)
/// - Business Logic Handler - performs the actual business logic (e.g. database access)
///
/// # Thread safety
///
/// A `ChannelHandler` can be added or removed at any time because a `ChannelPipeline` is thread safe.
public final class ChannelPipeline : ChannelInvoker {
    private var head: ChannelHandlerContext?
    private var tail: ChannelHandlerContext?
    
    private var idx: Int = 0
    private var destroyed: Bool = false
    
    /// The `EventLoop` that is used by the underlying `Channel`.
    public var eventLoop: EventLoop {
        return channel.eventLoop
    }

    /// The `Channel` that this `ChannelPipeline` belongs to.
    public unowned let channel: Channel

    /// Add a `ChannelHandler` to the `ChannelPipeline`.
    ///
    /// - parameters:
    ///     - name: the name to use for the `ChannelHandler` when its added. If none is specified it will generate a name.
    ///     - handler: the `ChannelHandler` to add
    ///     - first: `true` to add this handler to the front of the `ChannelPipeline`, `false to add it last
    /// - returns: the `EventLoopFuture` which will be notified once the `ChannelHandler` was added.
    public func add(name: String? = nil, handler: ChannelHandler, first: Bool = false) -> EventLoopFuture<Void> {
        let promise: EventLoopPromise<Void> = eventLoop.newPromise()
        if eventLoop.inEventLoop {
            add0(name: name, handler: handler, first: first, promise: promise)
        } else {
            eventLoop.execute {
                self.add0(name: name, handler: handler, first: first, promise: promise)
            }
        }
        return promise.futureResult
    }

    fileprivate static func keyPaths(fromHead: Bool, includeInbound: Bool, includeOutbound: Bool) -> [ChannelPipelineListKeyPathTriple] {
        let inboundFromHead: ChannelPipelineListKeyPathTriple = (\ChannelPipeline.head, \ChannelHandlerContext.inboundNext, \ChannelHandlerContext.inboundPrev)
        let outboundFromHead: ChannelPipelineListKeyPathTriple = (\ChannelPipeline.head, \ChannelHandlerContext.outboundPrev, \ChannelHandlerContext.outboundNext)
        let inboundFromTail: ChannelPipelineListKeyPathTriple = (\ChannelPipeline.tail, \ChannelHandlerContext.inboundPrev, \ChannelHandlerContext.inboundNext)
        let outboundFromTail: ChannelPipelineListKeyPathTriple = (\ChannelPipeline.tail, \ChannelHandlerContext.outboundNext, \ChannelHandlerContext.outboundPrev)
        let selector: CountableRange<Int> = (includeInbound ? 0 : 1)..<(includeOutbound ? 2 : 1)

        return Array([fromHead ? inboundFromHead : inboundFromTail,
                      fromHead ? outboundFromHead : outboundFromTail][selector])
    }

    private func keyPaths(fromHead: Bool, includeInbound: Bool, includeOutbound: Bool) -> [ChannelPipelineListKeyPathTriple] {
            /* use the globally cached version of the keypath triples */
            return linkedListKeyPaths[(fromHead ? 1 : 0) << 0 | (includeInbound ? 1 : 0) << 1 | (includeOutbound ? 1 : 0) << 2]
    }

    /// Add the handler to the `ChannelPipeline`. This operation must only be called when within the `EventLoop` thread.
    private func add0(name: String?, handler: ChannelHandler, first: Bool, promise: EventLoopPromise<Void>) {
        assert(eventLoop.inEventLoop)

        if destroyed {
            promise.fail(error: ChannelError.ioOnClosedChannel)
            return
        }
        
        let ctx = ChannelHandlerContext(name: name ?? nextName(), handler: handler, pipeline: self)
        ctx.outboundNext = tail
        let keyPaths = self.keyPaths(fromHead: first, includeInbound: handler is _ChannelInboundHandler, includeOutbound: handler is _ChannelOutboundHandler)
        for (headKP, nextKP, prevKP) in keyPaths {
            let head: ChannelHandlerContext = self[keyPath: headKP]!
            let next: ChannelHandlerContext = head[keyPath: nextKP]!
            
            ctx[keyPath: prevKP] = head
            ctx[keyPath: nextKP] = next
            head[keyPath: nextKP] = ctx
            next[keyPath: prevKP] = ctx
        }
        
        do {
            try ctx.invokeHandlerAdded()
            promise.succeed(result: ())
        } catch let err {
            remove0(ctx: ctx, promise: nil)

            promise.fail(error: err)
        }
    }
    
    /// Remove a `ChannelHandler` from the `ChannelPipeline`.
    ///
    /// - parameters:
    ///     - handler: the `ChannelHandler` to remove.
    /// - returns: the `EventLoopFuture` which will be notified once the `ChannelHandler` was removed.
    public func remove(handler: ChannelHandler) -> EventLoopFuture<Bool> {
        let promise: EventLoopPromise<Bool> = self.eventLoop.newPromise()
        context0({
            return $0.handler === handler
        }).then { ctx in
            self.remove0(ctx: ctx, promise: promise)
        }.cascadeFailure(promise: promise)
        return promise.futureResult
    }
    
    /// Remove a `ChannelHandler` from the `ChannelPipeline`.
    ///
    /// - parameters:
    ///     - name: the name that was used to add the `ChannelHandler` to the `ChannelPipeline` before.
    /// - returns: the `EventLoopFuture` which will be notified once the `ChannelHandler` was removed.
    public func remove(name: String) -> EventLoopFuture<Bool> {
        let promise: EventLoopPromise<Bool> = self.eventLoop.newPromise()
        context0({ $0.name == name }).then { ctx in
            self.remove0(ctx: ctx, promise: promise)
        }.cascadeFailure(promise: promise)
        return promise.futureResult
    }
    
    /// Remove a `ChannelHandler` from the `ChannelPipeline`.
    ///
    /// - parameters:
    ///     - ctx: the `ChannelHandlerContext` that belongs to `ChannelHandler` that should be removed.
    /// - returns: the `EventLoopFuture` which will be notified once the `ChannelHandler` was removed.
    public func remove(ctx: ChannelHandlerContext) -> EventLoopFuture<Bool> {
        let promise: EventLoopPromise<Bool> = self.eventLoop.newPromise()
        if self.eventLoop.inEventLoop {
            remove0(ctx: ctx, promise: promise)
        } else {
            self.eventLoop.execute {
                self.remove0(ctx: ctx, promise: promise)
            }
        }
        return promise.futureResult
    }
    
    /// Returns the `ChannelHandlerContext` that belongs to a `ChannelHandler`.
    ///
    /// - parameters:
    ///     - handler: the `ChannelHandler` for which the `ChannelHandlerContext` shoud be returned
    /// - returns: the `EventLoopFuture` which will be notified once the the operation completes.
    public func context(handler: ChannelHandler) -> EventLoopFuture<ChannelHandlerContext> {
        return context0({ $0.handler === handler })
    }
    
    /// Returns the `ChannelHandlerContext` that belongs to a `ChannelHandler`.
    ///
    /// - parameters:
    ///     - name: the name that was used to add the `ChannelHandler` to the `ChannelPipeline` before.
    /// - returns: the `EventLoopFuture` which will be notified once the the operation completes.
    public func context(name: String) -> EventLoopFuture<ChannelHandlerContext> {
        return context0({ $0.name == name })
    }

    /// Find a `ChannelHandlerContext` in the `ChannelPipeline`.
    private func context0(_ fn: @escaping ((ChannelHandlerContext) -> Bool)) -> EventLoopFuture<ChannelHandlerContext> {
        let promise: EventLoopPromise<ChannelHandlerContext> = eventLoop.newPromise()
        
        func _context0() {
            let keyPaths = self.keyPaths(fromHead: true, includeInbound: true, includeOutbound: true)
            for (head, next, _) in keyPaths {
                var curCtx: ChannelHandlerContext? = self[keyPath: head]
                while true {
                    if let ctx = curCtx {
                        if fn(ctx) {
                            promise.succeed(result: ctx)
                            return
                        }
                        curCtx = ctx[keyPath: next]
                    } else {
                        break
                    }
                }
            }
            promise.fail(error: ChannelPipelineError.notFound)
        }
        if eventLoop.inEventLoop {
            _context0()
        } else {
            eventLoop.execute {
                _context0()
            }
        }
        return promise.futureResult
    }
    
    /// Remove a `ChannelHandlerContext` from the `ChannelPipeline`. Must only be called from within the `EventLoop`.
    private func remove0(ctx: ChannelHandlerContext, promise: EventLoopPromise<Bool>?) {
        assert(self.eventLoop.inEventLoop)
        
        ctx.pipeline = nil

        let keyPaths = self.keyPaths(fromHead: true, includeInbound: true, includeOutbound: true)
        // Update the linked list structure
        for (_, next, prev) in keyPaths {
            let nextCtx = ctx[keyPath: next]
            let prevCtx = ctx[keyPath: prev]
            if let prevCtx = prevCtx {
                prevCtx[keyPath: next] = nextCtx
            }
            if let nextCtx = nextCtx {
                nextCtx[keyPath: prev] = prevCtx
            }
        }
        
        do {
            try ctx.invokeHandlerRemoved()
            promise?.succeed(result: true)
        } catch let err {
            promise?.fail(error: err)
        }

        // We need to keep the current node alive until after the callout in case the user uses the context.
        for (_, next, prev) in keyPaths {
            ctx[keyPath: next] = nil
            ctx[keyPath: prev] = nil
        }
    }
    
    /// Returns the next name to use for a `ChannelHandler`.
    private func nextName() -> String {
        assert(eventLoop.inEventLoop)

        let name = "handler\(idx)"
        idx += 1
        return name
    }

    /// Remove all the `ChannelHandler`s from the `ChannelPipeline` and destroy these. This method must only be called from within the `EventLoop`.
    func removeHandlers() {
        assert(eventLoop.inEventLoop)
        
        for (headKP, nextKP, _) in self.keyPaths(fromHead: true, includeInbound: true, includeOutbound: true) {
            if let head = self[keyPath: headKP] {
                while let ctx = head[keyPath: nextKP] {
                    remove0(ctx: ctx, promise: nil)
                }
                remove0(ctx: self[keyPath: headKP]!, promise: nil)
            }
        }
        self.head = nil
        self.tail = nil
        
        destroyed = true
    }
    
    // Just delegate to the head and tail context
    public func fireChannelRegistered() {
        if eventLoop.inEventLoop {
            fireChannelRegistered0()
        } else {
            eventLoop.execute {
                self.fireChannelRegistered0()
            }
        }
    }
   
    public func fireChannelUnregistered() {
        if eventLoop.inEventLoop {
            fireChannelUnregistered0()
        } else {
            eventLoop.execute {
                self.fireChannelUnregistered0()
            }
        }
    }
    
    public func fireChannelInactive() {
        if eventLoop.inEventLoop {
            fireChannelInactive0()
        } else {
            eventLoop.execute {
                self.fireChannelInactive0()
            }
        }
    }
    
    public func fireChannelActive() {
        if eventLoop.inEventLoop {
            fireChannelActive0()
        } else {
            eventLoop.execute {
                self.fireChannelActive0()
            }
        }
    }
    
    public func fireChannelRead(data: NIOAny) {
        if eventLoop.inEventLoop {
            fireChannelRead0(data: data)
        } else {
            eventLoop.execute {
                self.fireChannelRead0(data: data)
            }
        }
    }
    
    public func fireChannelReadComplete() {
        if eventLoop.inEventLoop {
            fireChannelReadComplete0()
        } else {
            eventLoop.execute {
                self.fireChannelReadComplete0()
            }
        }
    }

    public func fireChannelWritabilityChanged() {
        if eventLoop.inEventLoop {
            fireChannelWritabilityChanged0()
        } else {
            eventLoop.execute {
                self.fireChannelWritabilityChanged0()
            }
        }
    }
    
    public func fireUserInboundEventTriggered(event: Any) {
        if eventLoop.inEventLoop {
            fireUserInboundEventTriggered0(event: event)
        } else {
            eventLoop.execute {
                self.fireUserInboundEventTriggered0(event: event)
            }
        }
    }
    
    public func fireErrorCaught(error: Error) {
        if eventLoop.inEventLoop {
            fireErrorCaught0(error: error)
        } else {
            eventLoop.execute {
                self.fireErrorCaught0(error: error)
            }
        }
    }

    public func close(mode: CloseMode = .all, promise: EventLoopPromise<Void>?) {
        if eventLoop.inEventLoop {
            close0(mode: mode, promise: promise)
        } else {
            eventLoop.execute {
                self.close0(mode: mode, promise: promise)
            }
        }
    }

    public func flush(promise: EventLoopPromise<Void>?) {
        if eventLoop.inEventLoop {
            flush0(promise: promise)
        } else {
            eventLoop.execute {
                self.flush0(promise: promise)
            }
        }
    }
    
    public func read(promise: EventLoopPromise<Void>?) {
        if eventLoop.inEventLoop {
            read0(promise: promise)
        } else {
            eventLoop.execute {
                self.read0(promise: promise)
            }
        }
    }

    public func write(data: NIOAny, promise: EventLoopPromise<Void>?) {
        if eventLoop.inEventLoop {
            write0(data: data, promise: promise)
        } else {
            eventLoop.execute {
                self.write0(data: data, promise: promise)
            }
        }
    }

    public func writeAndFlush(data: NIOAny, promise: EventLoopPromise<Void>?) {
        if eventLoop.inEventLoop {
            writeAndFlush0(data: data, promise: promise)
        } else {
            eventLoop.execute {
                self.writeAndFlush0(data: data, promise: promise)
            }
        }
    }
    
    public func bind(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        if eventLoop.inEventLoop {
            bind0(to: address, promise: promise)
        } else {
            eventLoop.execute {
                self.bind0(to: address, promise: promise)
            }
        }
    }
    
    public func connect(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        if eventLoop.inEventLoop {
            connect0(to: address, promise: promise)
        } else {
            eventLoop.execute {
                self.connect0(to: address, promise: promise)
            }
        }
    }
    
    public func register(promise: EventLoopPromise<Void>?) {
        if eventLoop.inEventLoop {
            register0(promise: promise)
        } else {
            eventLoop.execute {
                self.register0(promise: promise)
            }
        }
    }
    
    public func triggerUserOutboundEvent(event: Any, promise: EventLoopPromise<Void>?) {
        if eventLoop.inEventLoop {
            triggerUserOutboundEvent0(event: event, promise: promise)
        } else {
            eventLoop.execute {
                self.triggerUserOutboundEvent0(event: event, promise: promise)
            }
        }
    }
    
    // These methods are expected to only be called from within the EventLoop
    
    private var firstOutboundCtx: ChannelHandlerContext? {
        return self.tail?.outboundNext
    }
    
    private var firstInboundCtx: ChannelHandlerContext? {
        return self.head?.inboundNext
    }
    
    func close0(mode: CloseMode, promise: EventLoopPromise<Void>?) {
        if let firstOutboundCtx = firstOutboundCtx {
            firstOutboundCtx.invokeClose(mode: mode, promise: promise)
        } else {
            promise?.fail(error: ChannelError.alreadyClosed)
        }
    }
    
    func flush0(promise: EventLoopPromise<Void>?) {
        if let firstOutboundCtx = firstOutboundCtx {
            firstOutboundCtx.invokeFlush(promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }
    
    func read0(promise: EventLoopPromise<Void>?) {
        if let firstOutboundCtx = firstOutboundCtx {
            firstOutboundCtx.invokeRead(promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }
    
    func write0(data: NIOAny, promise: EventLoopPromise<Void>?) {
        if let firstOutboundCtx = firstOutboundCtx {
            firstOutboundCtx.invokeWrite(data: data, promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }
    
    func writeAndFlush0(data: NIOAny, promise: EventLoopPromise<Void>?) {
        if let firstOutboundCtx = firstOutboundCtx {
            firstOutboundCtx.invokeWriteAndFlush(data: data, promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }
    
    func bind0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        if let firstOutboundCtx = firstOutboundCtx {
            firstOutboundCtx.invokeBind(to: address, promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }
    
    func connect0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        if let firstOutboundCtx = firstOutboundCtx {
            firstOutboundCtx.invokeConnect(to: address, promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }
    
    func register0(promise: EventLoopPromise<Void>?) {
        if let firstOutboundCtx = firstOutboundCtx {
            firstOutboundCtx.invokeRegister(promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }
    
    func triggerUserOutboundEvent0(event: Any, promise: EventLoopPromise<Void>?) {
        if let firstOutboundCtx = firstOutboundCtx {
            firstOutboundCtx.invokeTriggerUserOutboundEvent(event: event, promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }
    
    func fireChannelRegistered0() {
        if let firstInboundCtx = firstInboundCtx {
            firstInboundCtx.invokeChannelRegistered()
        }
    }
    
    func fireChannelUnregistered0() {
        if let firstInboundCtx = firstInboundCtx {
            firstInboundCtx.invokeChannelUnregistered()
        }
    }
    
    func fireChannelInactive0() {
        if let firstInboundCtx = firstInboundCtx {
            firstInboundCtx.invokeChannelInactive()
        }
    }
    
    func fireChannelActive0() {
        if let firstInboundCtx = firstInboundCtx {
            firstInboundCtx.invokeChannelActive()
        }
    }
    
    func fireChannelRead0(data: NIOAny) {
        if let firstInboundCtx = firstInboundCtx {
            firstInboundCtx.invokeChannelRead(data: data)
        }
    }
    
    func fireChannelReadComplete0() {
        if let firstInboundCtx = firstInboundCtx {
            firstInboundCtx.invokeChannelReadComplete()
        }
    }
    
    func fireChannelWritabilityChanged0() {
        if let firstInboundCtx = firstInboundCtx {
            firstInboundCtx.invokeChannelWritabilityChanged()
        }
    }
    
    func fireUserInboundEventTriggered0(event: Any) {
        if let firstInboundCtx = firstInboundCtx {
            firstInboundCtx.invokeUserInboundEventTriggered(event: event)
        }
    }
    
    func fireErrorCaught0(error: Error) {
        if let firstInboundCtx = firstInboundCtx {
            firstInboundCtx.invokeErrorCaught(error: error)
        }
    }
    
    private var inEventLoop : Bool {
        return eventLoop.inEventLoop
    }

    // Only executed from Channel
    init (channel: Channel) {
        self.channel = channel
        
        self.head = ChannelHandlerContext(name: "head", handler: HeadChannelHandler.sharedInstance, pipeline: self)
        self.tail = ChannelHandlerContext(name: "tail", handler: TailChannelHandler.sharedInstance, pipeline: self)
        self.head!.inboundNext = self.tail!
        self.tail!.inboundPrev = self.head
        self.tail!.outboundNext = self.head!
        self.head!.outboundPrev = self.tail
    }
}

/// Special `ChannelHandler` that forwards all events to the `Channel.Unsafe` implementation.
private final class HeadChannelHandler : _ChannelOutboundHandler {

    static let sharedInstance = HeadChannelHandler()

    private init() { }

    func register(ctx: ChannelHandlerContext, promise: EventLoopPromise<Void>?) {
        if let channel = ctx.channel {
            channel._unsafe.register0(promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }
    
    func bind(ctx: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        if let channel = ctx.channel {
            channel._unsafe.bind0(to: address, promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }
    
    func connect(ctx: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        if let channel = ctx.channel {
            channel._unsafe.connect0(to: address, promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }
    
    func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if let channel = ctx.channel {
            channel._unsafe.write0(data: data.forceAsIOData(), promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }
    
    func flush(ctx: ChannelHandlerContext, promise: EventLoopPromise<Void>?) {
        if let channel = ctx.channel {
            channel._unsafe.flush0(promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }
    
    func close(ctx: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        if let channel = ctx.channel {
            channel._unsafe.close0(error: mode.error, mode: mode, promise: promise)
        } else {
            promise?.fail(error: ChannelError.alreadyClosed)
        }
    }
    
    func read(ctx: ChannelHandlerContext, promise: EventLoopPromise<Void>?) {
        if let channel = ctx.channel {
            channel._unsafe.read0(promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }
    
    func triggerUserOutboundEvent(ctx: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        if let channel = ctx.channel {
            channel._unsafe.triggerUserOutboundEvent0(event: event, promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }
    
}

private extension CloseMode {
    var error: ChannelError {
        switch self {
        case .all:
            return ChannelError.alreadyClosed
        case .output:
            return ChannelError.outputClosed
        case .input:
            return ChannelError.inputClosed
        }
    }
}

/// Special `ChannelInboundHandler` which will consume all inbound events.
private final class TailChannelHandler : _ChannelInboundHandler, _ChannelOutboundHandler {
    
    static let sharedInstance = TailChannelHandler()
    
    private init() { }

    func channelRegistered(ctx: ChannelHandlerContext) {
        // Discard
    }
    
    func channelUnregistered(ctx: ChannelHandlerContext) throws {
        // Discard
    }
    
    func channelActive(ctx: ChannelHandlerContext) {
        // Discard
    }
    
    func channelInactive(ctx: ChannelHandlerContext) {
        // Discard
    }
    
    func channelReadComplete(ctx: ChannelHandlerContext) {
        // Discard
    }
    
    func channelWritabilityChanged(ctx: ChannelHandlerContext) {
        // Discard
    }
    
    func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        // Discard
    }
    
    func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        ctx.channel!._unsafe.errorCaught0(error: error)
    }
    
    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        ctx.channel!._unsafe.channelRead0(data: data)
    }
}

/// `Error` that is used by the `ChannelPipeline` to inform the user of an error.
public enum ChannelPipelineError : Error {
    /// `ChannelHandler` was already removed.
    case alreadyRemoved
    /// `ChannelHandler` was not found.
    case notFound
}

/// Every `ChannelHandler` has -- when added to a `ChannelPipeline` -- a corresponding `ChannelHandlerContext` which is
/// the way `ChannelHandler`s can interact with other `ChannelHandler`s in the pipeline.
///
/// Most `ChannelHandler`s need to send events through the `ChannelPipeline` which they do by calling the respective
/// method on their `ChannelHandlerContext`. In fact all the `ChannelHandler` default implementations just forward
/// the event using the `ChannelHandlerContext`.
///
/// Many events are instrumental for a `ChannelHandler`'s life-cycle and it is therefore very important to send them
/// at the right point in time. Often, the right behaviour is to react to an event and then forward it to the next
/// `ChannelHandler`.
public final class ChannelHandlerContext : ChannelInvoker {
    
    // visible for ChannelPipeline to modify
    fileprivate var outboundNext: ChannelHandlerContext?
    fileprivate var outboundPrev: ChannelHandlerContext?
    
    fileprivate var inboundNext: ChannelHandlerContext?
    fileprivate var inboundPrev: ChannelHandlerContext?
    
    public fileprivate(set) var pipeline: ChannelPipeline?
    
    public var channel: Channel? {
        return pipeline?.channel
    }
    
    public let handler: ChannelHandler
    
    public let name: String
    public let eventLoop: EventLoop
    private let inboundHandler: _ChannelInboundHandler!
    private let outboundHandler: _ChannelOutboundHandler!
    
    // Only created from within ChannelPipeline
    fileprivate init(name: String, handler: ChannelHandler, pipeline: ChannelPipeline) {
        self.name = name
        self.handler = handler
        self.pipeline = pipeline
        self.eventLoop = pipeline.eventLoop
        if let handler = handler as? _ChannelInboundHandler {
            self.inboundHandler = handler
        } else {
            self.inboundHandler = nil
        }
        if let handler = handler as? _ChannelOutboundHandler {
            self.outboundHandler = handler
        } else {
            self.outboundHandler = nil
        }
    }
    
    /// Send a `channelRegistered` event to the next (inbound) `ChannelHandler` in the `ChannelPipeline`.
    ///
    /// - note: For correct operation it is very important to forward any `channelRegistered` event using this method at the right point in time, that is usually when received.
    public func fireChannelRegistered() {
        if let inboundNext = inboundNext {
            inboundNext.invokeChannelRegistered()
        }
    }

    /// Send a `channelUnregistered` event to the next (inbound) `ChannelHandler` in the `ChannelPipeline`.
    ///
    /// - note: For correct operation it is very important to forward any `channelUnregistered` event using this method at the right point in time, that is usually when received.
    public func fireChannelUnregistered() {
        if let inboundNext = inboundNext {
            inboundNext.invokeChannelUnregistered()
        }
    }
    
    /// Send a `channelActive` event to the next (inbound) `ChannelHandler` in the `ChannelPipeline`.
    ///
    /// - note: For correct operation it is very important to forward any `channelActive` event using this method at the right point in time, that is often when received.
    public func fireChannelActive() {
        if let inboundNext = inboundNext {
            inboundNext.invokeChannelActive()
        }
    }

    /// Send a `channelInactive` event to the next (inbound) `ChannelHandler` in the `ChannelPipeline`.
    ///
    /// - note: For correct operation it is very important to forward any `channelInactive` event using this method at the right point in time, that is often when received.
    public func fireChannelInactive() {
        if let inboundNext = inboundNext {
            inboundNext.invokeChannelInactive()
        }
    }
    
    /// Send data to the next inbound `ChannelHandler`. The data should be of type `ChannelInboundHandler.InboundOut`.
    public func fireChannelRead(data: NIOAny) {
        if let inboundNext = inboundNext {
            inboundNext.invokeChannelRead(data: data)
        }
    }
    
    /// Signal to the next `ChannelHandler` that a read burst has finished.
    public func fireChannelReadComplete() {
        if let inboundNext = inboundNext {
            inboundNext.invokeChannelReadComplete()
        }
    }
    
    /// Send a `writabilityChanged` event to the next (inbound) `ChannelHandler` in the `ChannelPipeline`.
    ///
    /// - note: For correct operation it is very important to forward any `writabilityChanged` event using this method at the right point in time, that is usually when received.
    public func fireChannelWritabilityChanged() {
        if let inboundNext = inboundNext {
            inboundNext.invokeChannelWritabilityChanged()
        }
    }
    
    /// Send an error to the next inbound `ChannelHandler`.
    public func fireErrorCaught(error: Error) {
        if let inboundNext = inboundNext {
            inboundNext.invokeErrorCaught(error: error)
        }
    }
    
    /// Send a user event to the next inbound `ChannelHandler`.
    public func fireUserInboundEventTriggered(event: Any) {
        if let inboundNext = inboundNext {
            inboundNext.invokeUserInboundEventTriggered(event: event)
        }
    }
    
    /// Send a `register` event to the next (outbound) `ChannelHandler` in the `ChannelPipeline`.
    ///
    /// - note: For correct operation it is very important to forward any `register` event using this method at the right point in time, that is usually when received.
    public func register(promise: EventLoopPromise<Void>?) {
        if let outboundNext = outboundNext {
            outboundNext.invokeRegister(promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }
    
    /// Send a `bind` event to the next outbound `ChannelHandler` in the `ChannelPipeline`.
    /// When the `bind` event reaches the `HeadChannelHandler` a `ServerSocketChannel` will be bound.
    ///
    /// - parameters:
    ///     - address: The address to bind to.
    ///     - promise: The promise fulfilled when the socket is bound or failed if it cannot be bound.
    public func bind(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        if let outboundNext = outboundNext {
            outboundNext.invokeBind(to: address, promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }
    
    /// Send a `connect` event to the next outbound `ChannelHandler` in the `ChannelPipeline`.
    /// When the `connect` event reaches the `HeadChannelHandler` a `SocketChannel` will be connected.
    ///
    /// - parameters:
    ///     - address: The address to connect to.
    ///     - promise: The promise fulfilled when the socket is connected or failed if it cannot be connected.
    public func connect(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        if let outboundNext = outboundNext {
            outboundNext.invokeConnect(to: address, promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }

    /// Send a `write` event to the next outbound `ChannelHandler` in the `ChannelPipeline`.
    /// When the `write` event reaches the `HeadChannelHandler` the data will be enqueued to be written on the next
    /// `flush` event.
    ///
    /// - parameters:
    ///     - data: The data to write, should be of type `ChannelOutboundHandler.OutboundOut`.
    ///     - promise: The promise fulfilled when the data has been written or failed if it cannot be written.
    public func write(data: NIOAny, promise: EventLoopPromise<Void>?) {
        if let outboundNext = outboundNext {
            outboundNext.invokeWrite(data: data, promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }

    /// Send a `flush` event to the next outbound `ChannelHandler` in the `ChannelPipeline`.
    /// When the `flush` event reaches the `HeadChannelHandler` the data previously enqueued will be attempted to be
    /// written to the socket.
    ///
    /// - parameters:
    ///     - promise: The promise fulfilled when the previously written data been flushed or failed if it cannot be flushed.
    public func flush(promise: EventLoopPromise<Void>?) {
        if let outboundNext = outboundNext {
            outboundNext.invokeFlush(promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }
    
    /// Send a `write` event followed by a `flush` event to the next outbound `ChannelHandler` in the `ChannelPipeline`.
    /// When the `write` event reaches the `HeadChannelHandler` the data will be enqueued to be written when the `flush`
    /// also reaches the `HeadChannelHandler`.
    ///
    /// - parameters:
    ///     - data: The data to write, should be of type `ChannelOutboundHandler.OutboundOut`.
    ///     - promise: The promise fulfilled when the previously written data been written and flushed or if that failed.
    public func writeAndFlush(data: NIOAny, promise: EventLoopPromise<Void>?) {
        if let outboundNext = outboundNext {
            outboundNext.invokeWriteAndFlush(data: data, promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }
    
    /// Send a `read` event to the next outbound `ChannelHandler` in the `ChannelPipeline`.
    /// When the `read` event reaches the `HeadChannelHandler` the interest to read data will be signalled to the
    /// `Selector`. This will subsequently -- when data becomes readable -- cause `channelRead` events containing the
    /// data being sent through the `ChannelPipeline`.
    ///
    /// - parameters:
    ///     - promise: The promise fulfilled when data has been read or failed if it that failed.
    public func read(promise: EventLoopPromise<Void>?) {
        if let outboundNext = outboundNext {
            outboundNext.invokeRead(promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }

    /// Send a `close` event to the next outbound `ChannelHandler` in the `ChannelPipeline`.
    /// When the `close` event reaches the `HeadChannelHandler` the socket will be closed.
    ///
    /// - parameters:
    ///     - mode: The `CloseMode` to use.
    ///     - promise: The promise fulfilled when the `Channel` has been closed or failed if it the closing failed.
    public func close(mode: CloseMode = .all, promise: EventLoopPromise<Void>?) {
        if let outboundNext = outboundNext {
            outboundNext.invokeClose(mode: mode, promise: promise)
        } else {
            promise?.fail(error: ChannelError.alreadyClosed)
        }
    }
    
    /// Send a user event to the next outbound `ChannelHandler` in the `ChannelPipeline`.
    ///
    /// - parameters:
    ///     - event: The user event to send.
    ///     - promise: The promise fulfilled when the user event has been sent or failed if it couldn't be sent.
    public func triggerUserOutboundEvent(event: Any, promise: EventLoopPromise<Void>?) {
        if let outboundNext = outboundNext {
            outboundNext.invokeTriggerUserOutboundEvent(event: event, promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }
    
    fileprivate func invokeChannelRegistered() {
        assert(inEventLoop)
        
        do {
            try self.inboundHandler.channelRegistered(ctx: self)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    fileprivate func invokeChannelUnregistered() {
        assert(inEventLoop)
        
        do {
            try self.inboundHandler.channelUnregistered(ctx: self)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    fileprivate func invokeChannelActive() {
        assert(inEventLoop)
        
        do {
            try self.inboundHandler.channelActive(ctx: self)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    fileprivate func invokeChannelInactive() {
        assert(inEventLoop)
        
        do {
            try self.inboundHandler.channelInactive(ctx: self)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    fileprivate func invokeChannelRead(data: NIOAny) {
        assert(inEventLoop)
        
        do {
            try self.inboundHandler.channelRead(ctx: self, data: data)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    fileprivate func invokeChannelReadComplete() {
        assert(inEventLoop)
        
        do {
            try self.inboundHandler.channelReadComplete(ctx: self)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    fileprivate func invokeChannelWritabilityChanged() {
        assert(inEventLoop)
        
        do {
            try self.inboundHandler.channelWritabilityChanged(ctx: self)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    fileprivate func invokeErrorCaught(error: Error) {
        assert(inEventLoop)
        
        do {
            try self.inboundHandler.errorCaught(ctx: self, error: error)
        } catch let err {
            // Forward the error thrown by errorCaught through the pipeline
            fireErrorCaught(error: err)
        }
    }
    
    fileprivate func invokeUserInboundEventTriggered(event: Any) {
        assert(inEventLoop)
        
        do {
            try self.inboundHandler.userInboundEventTriggered(ctx: self, event: event)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    fileprivate func invokeRegister(promise: EventLoopPromise<Void>?) {
        assert(inEventLoop)
        assert(promise.map { !$0.futureResult.fulfilled } ?? true, "Promise \(promise!) already fulfilled")
        
        self.outboundHandler.register(ctx: self, promise: promise)
    }
    
   fileprivate func invokeBind(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        assert(inEventLoop)
        assert(promise.map { !$0.futureResult.fulfilled } ?? true, "Promise \(promise!) already fulfilled")

        self.outboundHandler.bind(ctx: self, to: address, promise: promise)
    }
    
    fileprivate func invokeConnect(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        assert(inEventLoop)
        assert(promise.map { !$0.futureResult.fulfilled } ?? true, "Promise \(promise!) already fulfilled")

        self.outboundHandler.connect(ctx: self, to: address, promise: promise)
    }

    fileprivate func invokeWrite(data: NIOAny, promise: EventLoopPromise<Void>?) {
        assert(inEventLoop)
        assert(promise.map { !$0.futureResult.fulfilled } ?? true, "Promise \(promise!) already fulfilled")

        self.outboundHandler.write(ctx: self, data: data, promise: promise)
    }

    fileprivate func invokeFlush(promise: EventLoopPromise<Void>?) {
        assert(inEventLoop)
        
        self.outboundHandler.flush(ctx: self, promise: promise)
    }
    
    fileprivate func invokeWriteAndFlush(data: NIOAny, promise: EventLoopPromise<Void>?) {
        assert(inEventLoop)
        assert(promise.map { !$0.futureResult.fulfilled } ?? true, "Promise \(promise!) already fulfilled")
        
        if let promise = promise {
            var counter = 2
            let callback: (EventLoopFutureValue<Void>) -> Void = { v in
                switch v {
                case .failure(let err):
                    promise.fail(error: err)
                case .success(_):
                    counter -= 1
                    if counter == 0 {
                        promise.succeed(result: ())
                    }
                    assert(counter >= 0)
                }
            }
            
            let writePromise: EventLoopPromise<Void> = eventLoop.newPromise()
            let flushPromise: EventLoopPromise<Void> = eventLoop.newPromise()
            
            self.outboundHandler.write(ctx: self, data: data, promise: writePromise)
            self.outboundHandler.flush(ctx: self, promise: flushPromise)
            
            writePromise.futureResult.whenComplete(callback: callback)
            flushPromise.futureResult.whenComplete(callback: callback)
        } else {
            self.outboundHandler.write(ctx: self, data: data, promise: nil)
            self.outboundHandler.flush(ctx: self, promise: nil)
        }
    }
    
    fileprivate func invokeRead(promise: EventLoopPromise<Void>?) {
        assert(inEventLoop)
        
        self.outboundHandler.read(ctx: self, promise: promise)
    }
    
    fileprivate func invokeClose(mode: CloseMode, promise: EventLoopPromise<Void>?) {
        assert(inEventLoop)
        assert(promise.map { !$0.futureResult.fulfilled } ?? true, "Promise \(promise!) already fulfilled")

        self.outboundHandler.close(ctx: self, mode: mode, promise: promise)
    }
    
    fileprivate func invokeTriggerUserOutboundEvent(event: Any, promise: EventLoopPromise<Void>?) {
        assert(inEventLoop)
        assert(promise.map { !$0.futureResult.fulfilled } ?? true, "Promise \(promise!) already fulfilled")
        
        self.outboundHandler.triggerUserOutboundEvent(ctx: self, event: event, promise: promise)
    }
    
    fileprivate func invokeHandlerAdded() throws {
        assert(inEventLoop)
        
        try handler.handlerAdded(ctx: self)
    }
    
    fileprivate func invokeHandlerRemoved() throws {
        assert(inEventLoop)
        try handler.handlerRemoved(ctx: self)
    }
    
    private var inEventLoop : Bool {
        return eventLoop.inEventLoop
    }
}

extension ChannelPipeline: CustomDebugStringConvertible {
    public var debugDescription: String {
        var desc = "ChannelPipeline:\n"
        desc    += "    INBOUND\n"
        var (head, next, _) = self.keyPaths(fromHead: true, includeInbound: true, includeOutbound: false).first!
        var node = self[keyPath: head]
        while let ctx = node {
            desc += "        \(ctx.name)\n"
            node = ctx[keyPath: next]
        }
        desc    += "    OUTBOUND\n"
        (head, next, _) = self.keyPaths(fromHead: true, includeInbound: false, includeOutbound: true).first!
        node = self[keyPath: head]
        while let ctx = node {
            desc += "        \(ctx.name)\n"
            node = ctx[keyPath: next]
        }
        return desc
    }
}
