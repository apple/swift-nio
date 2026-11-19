# Promise and Event Ordering in Channel Implementations

This article explains in which order a ``Channel`` implementation should fulfill
its promises and fire its pipeline events.

Almost every operation on a ``Channel`` has two visible outcomes. The first one
is private to the caller: the ``EventLoopPromise`` that was passed to the
operation, or the ``EventLoopFuture`` that was returned from it. The second one
is public to everybody in the ``ChannelPipeline``: an inbound event such as
``ChannelInboundInvoker/fireChannelActive()`` or
``ChannelInboundInvoker/fireChannelInactive()`` that announces the resulting
state change.

The order in which these two outcomes are delivered is not an implementation
detail. Handlers rely on it, and NIO's own handlers rely on it. If you write
your own ``Channel`` — and therefore your own ``ChannelCore`` — you should
uphold the same order that NIO's channels uphold, otherwise handlers that work
on a `NIOPosix` channel may subtly misbehave on yours.

> Note: This article is only relevant if you are implementing the ``ChannelCore``
protocol. Its methods are public, but they exist for the use of the ``Channel``
implementation itself and should only ever be called from the channel's
``EventLoop``. If you are writing a ``ChannelHandler``, read this article as a
description of the guarantees you are given, and keep using
``ChannelOutboundInvoker`` to drive the channel.

## The golden rule

Every state changing operation on a ``Channel`` follows the same four steps, in
this order:

1. **Reconcile the state.** Perform the actual work and update all state that is
   observable from a handler, for example `isActive`, `isWritable`, the cached
   addresses and the state of your outbound buffer. Do not call out to user code
   while doing this.
2. **Fulfill the operation's promise.** Succeed or fail the ``EventLoopPromise``
   that the caller handed to the ``ChannelCore`` method.
3. **Fire the matching pipeline event.** Only now announce the new state to the
   ``ChannelPipeline``.
4. **Fire ``Channel/closeFuture`` last of all**, and only when the channel is
   being torn down. This happens after the pipeline has been dismantled, on a
   later event loop tick.

Or, condensed into a single sentence that is worth remembering:

> Important: State first, then the promise, then the pipeline event, and
``Channel/closeFuture`` last.

There is a reason for this order. The promise is the answer to a question that
one specific caller asked, and that caller is entitled to learn the outcome of
its own operation before the rest of the world is told about the consequences. A
pipeline event is a broadcast: by the time a handler receives
`channelInactive(context:)` it is entitled to assume
that everything that led to the channel becoming inactive has already been
resolved. This means a handler can, for example, safely assume in
`channelActive(context:)` that the promise of the
`connect` that caused the activation has already been fulfilled, and that
`context.channel.isActive` already returns `true`.

The rest of this article works through each operation in turn.

### Registration

Registration is the simplest case. Reconcile the state, succeed the promise,
then fire ``ChannelInboundInvoker/fireChannelRegistered()``:

```swift
public func register0(promise: EventLoopPromise<Void>?) {
    self.eventLoop.assertInEventLoop()

    guard self.isOpen else {
        promise?.fail(ChannelError.ioOnClosedChannel)
        return
    }
    guard !self.isRegistered else {
        promise?.fail(ChannelError.inappropriateOperationForState)
        return
    }

    // 1. reconcile state
    self.state = .registered

    // 2. the caller's promise
    promise?.succeed(())

    // 3. the broadcast
    self.pipeline.syncOperations.fireChannelRegistered()
}
```

A handler receiving `channelRegistered` may therefore assume that the promise
returned by `register()` has already been fulfilled, and that
`channel.isActive` is still `false`.

### Activation

Activation is what `bind` does for a listening channel and what `connect` does
for a connected channel. The promise that is fulfilled here is the promise of
the operation that caused the activation — the bind promise or the connect
promise — not a separate "activation promise".

```swift
func becomeActive0(promise: EventLoopPromise<Void>?) {
    // 1. reconcile state; `isActive` should already return `true` after this
    self.state = .active

    // 2. the promise of the `bind` or `connect` that got us here
    promise?.succeed(())

    // 3. the broadcast
    self.pipeline.syncOperations.fireChannelActive()
}
```

Two things are worth spelling out.

First, if your activation is asynchronous — a `connect` that returns
`EINPROGRESS`, for example — you should hold on to the connect promise and only
fulfill it at the point where you actually become active. NIO stores it in a
`pendingConnect` property and passes it into the activation path once the
connection has been established. Avoid succeeding the connect promise early and
then firing `channelActive` later: that inverts the rule and gives handlers a
window in which the connect future has fired but the channel is not yet active.

Second, if activation is a consequence of a lower level operation that has its
own promise, the state change should still happen before that promise is
completed. `ServerSocketChannel.bind0` in `NIOPosix` is a good example: it
performs the `bind` and `listen` syscalls, and only in the success continuation
does it drive the activation, which in turn fulfills the user's bind promise.
The comment in that code is blunt about it: it is important to call the state
changing methods before notifying the original promise, for ordering reasons.

### Closing

Closing is where the ordering matters most, because there are many promises
involved and each of them should be resolved at the right point. The order below
is the one NIO uses for a full close, i.e. ``CloseMode/all``. The half-closure
modes are covered further down.

| Step | What happens |
| ---- | ------------ |
| 1 | Reject the operation outright if the channel is already closed |
| 2 | Do the actual work: deregister from the event loop, close the underlying resource. **No callouts to user code.** |
| 3 | Fail all pending **write** promises with the error that caused the close |
| 4 | Fail a pending **connect** promise, if there is one |
| 5 | Succeed (or fail) the **close** promise |
| 6 | Fire ``ChannelInboundInvoker/fireChannelInactive()`` |
| 7 | Fire ``ChannelInboundInvoker/fireChannelUnregistered()`` |
| 8 | On a **later event loop tick**: remove all handlers from the pipeline, then succeed ``Channel/closeFuture`` |

In skeleton form:

```swift
public func close0(error: Error, mode: CloseMode, promise: EventLoopPromise<Void>?) {
    self.eventLoop.assertInEventLoop()

    // 1. guards. Note that these fail the promise; they don't fire any events.
    guard self.isOpen else {
        promise?.fail(ChannelError.alreadyClosed)
        return
    }

    // === BEGIN: no user callouts ===
    //
    // 2. Do the work and reconcile the state. Any error that we discover in
    //    here is recorded and only fired once the state is consistent again.
    var errorCallouts: [(ChannelPipeline) -> Void] = []
    do {
        try self.deregisterFromEventLoop()
    } catch {
        errorCallouts.append { $0.syncOperations.fireErrorCaught(error) }
    }
    self.state = .closed  // `isActive` should now return `false`
    // === END: no user callouts ===

    // 3. all pending writes fail with the error that caused the close
    self.failPendingWrites(error: error)

    // the errors we recorded above
    for callout in errorCallouts {
        callout(self.pipeline)
    }

    // 4. an in-flight connect fails with the same error
    if let connectPromise = self.pendingConnect {
        self.pendingConnect = nil
        connectPromise.fail(error)
    }

    // 5. the caller's close promise
    promise?.succeed(())

    // 6. + 7. the broadcast
    self.pipeline.syncOperations.fireChannelInactive()
    self.pipeline.syncOperations.fireChannelUnregistered()

    // 8. delayed, so that user code can still traverse the pipeline
    self.eventLoop.execute {
        self.removeHandlers(pipeline: self.pipeline)
        self.closePromise.succeed(())
    }
}
```

Note the "no user callouts" region in the middle. While your state is only
half-updated you should avoid calling anything that can run user code, because
that code is allowed to call back into your channel and would observe an
inconsistent channel. Collect the errors you need to report in a local array and
fire them once the state is consistent again. This is also why the pending writes
are failed before anything else in the callout region: failing them transitions
the outbound buffer into its closed state, so it agrees with the rest of the
channel about being closed before any handler can look at it.

The practical consequences for users of your channel are worth internalizing:

```swift
channel.close().whenComplete { _ in
    // This runs *before* any handler in the pipeline sees `channelInactive`.
}

channel.closeFuture.whenComplete { _ in
    // This runs *after* `channelInactive`, `channelUnregistered` and
    // `handlerRemoved` for every handler in the pipeline.
}
```

### Why closeFuture is special

``Channel/closeFuture`` is not the result of the close operation, it is the
signal that the channel has finished being torn down. That gives it two
guidelines of its own.

It should be fulfilled last, and it should be fulfilled on a later event loop
tick than the `channelInactive` callout. The reason for the delay is that
handlers receiving `channelInactive` may still use their
``ChannelHandlerContext`` and traverse the pipeline; the pipeline should
therefore still be intact while they do. Only once that callout has fully
unwound is it safe to remove the handlers and fulfill `closeFuture`.

> Warning: ``Channel/closeFuture`` should never be failed, not even if the
close itself failed. It signals that the channel is closed, and that is not an
outcome that can fail. Errors that occurred during closure belong on the promise
that was passed to ``ChannelOutboundInvoker/close(mode:promise:)``.

### Half-closure

Half-closure follows the same rule with a user inbound event instead of a
lifecycle event, because the channel does not change its active state:

```swift
case .input:
    guard !self.inputShutdown else {
        promise?.fail(ChannelError.inputClosed)
        return
    }
    try self.shutdownSocket(mode: mode)   // 1. state
    self.unregisterForReadable()
    promise?.succeed(())                  // 2. promise
    self.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)  // 3. event
```

The output side is symmetric with ``ChannelEvent/outputClosed``. If a
half-closure request would close the last remaining direction, escalate it to a
full close rather than inventing a new order for it.

### Writes and writability

Writes are the most interesting application of the rule, because the state that
the promise's owner cares about is `isWritable`, and `isWritable` is a
consequence of the very write whose promise is about to be fulfilled.

Each individual write promise is fulfilled at the point where the corresponding
bytes have actually been handed off to the underlying transport. Before that
happens, the buffer accounting is updated and the `isWritable` flag is
recomputed. Only then does the promise succeed, and only once the write call that
drained the buffer has fully completed does
``ChannelInboundInvoker/fireChannelWritabilityChanged()`` announce the change to
the pipeline — never in between the individual write promises of a batch.

```swift
private func flushNow() {
    // Re-entrancy protection: a write issued from one of the callouts below is
    // picked up by this loop, rather than starting a nested flush.
    guard !self.inFlushNow else { return }
    self.inFlushNow = true
    defer { self.inFlushNow = false }

    var becameWritable = false

    while self.hasFlushedWrites && self.isOpen {
        do {
            // 1. state: write out what is buffered, and update everything a
            //    handler can observe. Determining the new writability belongs
            //    in here as well: it is a function of how much data is still
            //    buffered, so it can only be decided once the write is done.
            let completedWrites = try self.writeBufferedData()
            if !self.isWritable, self.hasDrainedBelowLowWaterMark {
                self.isWritable = true
                becameWritable = true
            }

            // 2. promises: now that `isWritable` is up to date, tell the
            //    writers that their writes have completed.
            for promise in completedWrites {
                promise.succeed(())
            }
        } catch {
            // A write error is owned by the write promises, so there is nothing
            // to fire here. Our own `close0` above fails all pending writes
            // with this error as step 3 of its sequence.
            self.close0(error: error, mode: .all, promise: nil)
            return
        }
    }

    // 3. the broadcast
    if becameWritable {
        self.pipeline.syncOperations.fireChannelWritabilityChanged()
    }
}
```

The order inside step 1 and 2 is deliberate, and it is worth being explicit
about why: a producer that suspends when the channel becomes unwritable typically
resumes from the write promise. When that promise runs, it will ask whether it
should produce more:

```swift
channel.writeAndFlush(chunk).whenSuccess {
    if channel.isWritable {
        produceMore()
    }
}
```

If you fulfilled the promise before updating the flag, this code would read a
stale `isWritable` and either stall or keep filling the buffer. So the flag has
to move first — which is nothing more than the golden rule applied to writability:
state, then the promise, then the event.

The pipeline event, on the other hand, deliberately comes last. It is a
broadcast, and firing it from inside the write loop, in between the promises of a
single batch, would expose handlers to a half-drained buffer. Note also that the
callout happens while the re-entrancy guard is still held, so a handler that
writes in response to `channelWritabilityChanged` does not start a nested flush;
its data is buffered and picked up by the enclosing loop.

> Note: `NIOPosix` implements the accounting and the flag update in
`PendingWritesManager`, which returns the promise to be fulfilled rather than
fulfilling it itself. That keeps the "update state, then call out" split
explicit: the manager is done mutating its state by the time the channel succeeds
the promise. It also stores the flag in an atomic, because ``Channel/isWritable``
may be queried from any thread — a detail the example above leaves out, as it is
orthogonal to the ordering.

The same argument applies in the other direction. When a write pushes the buffer
above the high water mark, `isWritable` should become `false` before
``ChannelInboundInvoker/fireChannelWritabilityChanged()`` is fired, so a handler
reacting to the event sees a value consistent with the event it just received.

## Errors

Error reporting is the least uniform part of a ``ChannelCore``, so it is worth
looking at what NIO actually does before picking a scheme for your own channel.

### Who learns about the error?

An error can reach the user in two ways: by failing a promise that somebody is
waiting on, or by being fired into the pipeline with
``ChannelInboundInvoker/fireErrorCaught(_:)``. Note that `close0` does not fire
the error it is handed: it uses that error to fail the pending writes and a
pending connect, and nothing more. Whether an error driven close also produces an
`errorCaught` therefore depends entirely on the code that *discovered* the error.

In `NIOPosix`, case by case:

- A **read** error, or a connection reset, is fired as `errorCaught` and then
  closes the channel. There is no outstanding promise that could carry it, so
  this is the only way to report it.
- A **write** error is not fired as `errorCaught`. The flush catches it, drains
  whatever is still readable, and closes the channel with that error; the error
  surfaces on the promises of the writes that did not complete. A write that was
  issued without a promise therefore has its error reported nowhere, beyond the
  channel going inactive.
- A **connect** error, including a connect timeout, is likewise not fired as
  `errorCaught`. It fails the connect promise, by way of the close.
- A **registration** failure does both: it fires `errorCaught`, closes the
  channel, and fails the register promise. A failing re-registration does the
  same, minus the promise, because there is none.
- A failing **deregistration** during a close is fired as `errorCaught`, whereas
  a failure to close the underlying resource fails the close promise instead.
- A non-fatal socket error on a **datagram** channel is fired as `errorCaught`
  without closing the channel at all.
- `ChannelError.eof` is neither: a remote close is a normal event, and it is
  reported as `channelInactive`, or as ``ChannelEvent/inputClosed`` if
  `allowRemoteHalfClosure` is set.

No single rule covers all of those, but there is a useful default. If a promise
owns the error, failing that promise is the primary report and firing
`errorCaught` as well is largely redundant. If nothing owns the error,
`errorCaught` is the only way to report it at all. Whichever you pick for a given
error path, be consistent about it, and avoid reporting the same error twice.

### An error that causes a close

`errorCaught` is never fired by the close sequence itself. Where it is fired, it
is fired by the code that *discovered* the error, before the close is started:

```swift
// e.g. in your read handling
self.pipeline.syncOperations.fireErrorCaught(error)         // first
self.close0(error: error, mode: .all, promise: nil)         // then the close sequence
```

So for an error driven close where the discovering code fires `errorCaught`, the
complete order is: `errorCaught`, then failed write promises, then a failed
connect promise, then the close promise, then `channelInactive`, then
`channelUnregistered`, and finally, one tick later, `handlerRemoved` and
`closeFuture`.

> Note: Internal, error driven closes pass `promise: nil`. There is no close
promise in that case because nobody asked for the close. The error still reaches
the user via the write and connect promises, and via `errorCaught` if the
discovering code fired it.

### An error thrown by the close itself

If the close operation itself fails — the deregistration throws, or closing the
underlying resource throws — that error is reported inside the close sequence,
after the state has been reconciled but still before the close promise and
before `channelInactive`. This is what the `errorCallouts` array in the skeleton
above is for.

There is one subtlety here. If closing the underlying resource fails, the
caller's close promise should be *failed* rather than succeeded, and you need to
make sure it is not also completed by the rest of the sequence:

```swift
let p: EventLoopPromise<Void>?
do {
    try self.socket.close()
    p = promise
} catch {
    errorCallouts.append { _ in promise?.fail(error) }
    // Pass `nil` on, so we do not try to notify the promise a second time.
    p = nil
}
```

Even in this failure case the promise completes before `channelInactive` — just
with a failure instead of a success.

### Racing closes

Because the whole sequence above runs synchronously on the event loop, a second
close that arrives afterwards hits the `isOpen` guard and fails immediately with
``ChannelError/alreadyClosed``. That is the behaviour to aim for: a close promise
should never be left dangling, and it should not be succeeded for a close that
did not happen.

## Re-entrancy

Every callout you make is a chance for user code to call back into your channel.
The most common case is a handler that closes the channel from within
`channelActive`. Your implementation should survive that, which in practice
means checking your own state again after every callout:

```swift
self.becomeActive0(promise: promise)   // may run user code that closes us
guard self.isActive else {
    // a handler closed the channel in the callout; stop here
    return
}
self.registerForReadEOF()
```

`NIOPosix` does exactly this twice in its activation path: once after the promise
is fulfilled, and once after `channelActive` has been fired. Assume that every
promise you complete and every event you fire can close your channel, and avoid
touching state after a callout without re-validating it.

## The one inversion: handlerAdded and handlerRemoved

``ChannelHandler/handlerAdded(context:)`` and
``ChannelHandler/handlerRemoved(context:)`` run *before* the promise of the
`addHandler`/`removeHandler` operation, which looks like the opposite of
everything above. It is not, and the distinction is useful.

`channelActive` and `channelInactive` are broadcasts about a state change that
has already happened elsewhere. `handlerAdded` is part of *performing* the
operation: a handler is not considered added until it has been told that it was
added. Read the rule as "the promise completes when the operation is genuinely
complete", and both cases are the same rule.

## Idempotency and guards

All the ``ChannelCore`` methods can be called at any time, including in states
where they make no sense, and ideally none of them trap. Fail the promise
instead, and use the errors NIO uses so that handlers can react to them
uniformly:

- ``ChannelError/alreadyClosed`` when the channel is already closed and a close
  is requested again.
- ``ChannelError/ioOnClosedChannel`` for any other operation on a closed
  channel.
- ``ChannelError/inappropriateOperationForState`` when the operation is valid
  for your channel but not in its current state, for example registering twice.
- ``ChannelError/operationUnsupported`` when your channel type does not support
  the operation at all, for example `connect` on a listening channel.
  ``CloseMode/input`` and ``CloseMode/output`` are optional modes, so this is
  also the error to use if your channel cannot half-close.
- ``ChannelError/inputClosed`` and ``ChannelError/outputClosed`` when a
  direction has already been shut down.

None of these guards fire pipeline events. A rejected operation did not change
any state, so there is nothing to broadcast.

## Checklist

When you implement or review a ``ChannelCore``, walk through this list:

- [ ] Every method asserts that it is running on the channel's ``EventLoop``.
- [ ] Every observable state change is complete before the first callout.
- [ ] The operation's promise is fulfilled before the corresponding pipeline
      event is fired.
- [ ] `isActive` returns `true` before `channelActive` is fired, and `false`
      before `channelInactive` is fired.
- [ ] Pending write promises and a pending connect promise are failed before the
      close promise is completed.
- [ ] `channelInactive` is fired before `channelUnregistered`.
- [ ] `channelInactive` is not fired for a channel that never became active.
- [ ] Handlers are removed, and ``Channel/closeFuture`` is fulfilled, on a later
      event loop tick, after every other notification.
- [ ] ``Channel/closeFuture`` is only ever succeeded, never failed.
- [ ] Every callout is followed by a re-validation of the state, because user
      code may have closed the channel.
- [ ] No method traps on an invalid state; each fails its promise with the
      appropriate ``ChannelError``.
