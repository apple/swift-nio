# Changes in the Public API from NIO 1 to NIO 2

- renamed all instances of `ctx` to `context`. Your `ChannelHandler` methods now
  need to take a `context` parameter and no longer `ctx`. Example: `func channelRead(context: ChannelHandlerContext, data: NIOAny)`
- removed all previously deprecated functions, types and modules.
- renamed `SniResult` to `SNIResult`
- renamed `SniHandler` to `SNIHandler`
- made `EventLoopGroup.makeIterator()` a required method
- `Channel._unsafe` is now `Channel._channelCore`
- `TimeAmount.Value` is now `Int64` (from `Int` on 64 bit platforms, no change
  for 32 bit platforms)
- `ByteToMessageDecoder`s now need to be wrapped in `ByteToMessageHandler`
  before they can be added to the pipeline.
  before: `pipeline.add(MyDecoder())`, after: `pipeline.add(ByteToMessageHandler(MyDecoder()))`
- `BlockingIOThreadPool` has been renamed to `NIOThreadPool`
- `ByteToMessageDecoder` now requires the implementation of `decodeLast`
- `ByteToMessageDecoder.decodeLast` has a new parameter `seenEOF: Bool`
- `EventLoop.makePromise`/`makeSucceededFuture`/`makeFailedFuture` instead of `new*`, also `result:`/`error:` labels dropped
- `SocketAddress.makeAddressResolvingHost(:port:)` instead of
  `SocketAddress.newAddressResolving(host:port:)`
- changed all ports to `Int` (from `UInt16`)
- changed `HTTPVersion`'s `major` and `minor` properties to `Int` (from `UInt16`)
- renamed the generic parameter name to `Bytes` where we're talking about a
  generic collection of bytes
- Moved error `ChannelLifecycleError.inappropriateOperationForState` to `ChannelError.inappropriateOperationForState`.
- Moved all errors in `MulticastError` enum into `ChannelError`.
- Removed `ChannelError.connectFailed`. All errors that triggered this now throw `NIOConnectError` directly.
- Made `WebSocketOpcode` a struct. Removed `WebSocketOpcode.unknownControl` and
  `WebSocketOpcode.unknownNonControl` values: these should be replaced by
  simply instantiating `WebSocketOpcode` with the value.
- `Channel.setOption(option:value:)` has been renamed `Channel.setOption(_:value:)`
- `Channel.getOption(option:value:)` has been renamed `Channel.getOption(_:value:)`
- `ChannelOption.AssociatedValueType` has been removed
- `ChannelOption.OptionType` has been renamed `ChannelOption.Value`
- the default `ChannelOption`s have been switched changed from `case FooOption { case const }` to a `struct FooOption { public init() {} }`
- `markedElementIndex()`, `markedElement()` and `hasMark()` are now computed variables instead of functions.
- `ByteBuffer.set(string:at:)` no longer returns an `Int?`, instead it
  returns `Int` and has had its return value made discardable.
- `ByteBuffer.write(string:)` (now named `ByteBuffer.writeString(_:)`) no longer returns an `Int?`, instead it
  returns `Int` and has had its return value made discardable.
- removed ContiguousCollection
- CircularBuffer(initialRingCapacity:) is now CircularBuffer(initialCapacity:)
- MarkedCircularBuffer(initialRingCapacity:) is now MarkedCircularBuffer(initialCapacity:)
- EventLoopFuture.whenComplete now provides Result<T, Error>
- renamed `EventLoopFuture.then` to `EventLoopFuture.flatMap`
- renamed `EventLoopFuture.thenIfError` to `EventLoopFuture.flatMapError`
- renamed `EventLoopFuture.mapIfError` to `EventLoopFuture.recover`
- renamed `EventLoopFuture.thenThrowing` to `EventLoopFuture.flatMapThrowing`
- renamed `EventLoopFuture`'s generic parameter from `T` to `Value`
- renamed `EventLoopFuture.and(result:)` to `EventLoopFuture.and(value:)`
- `EventLoopPromise.succeed(result: Value)` lost its label so is now `EventLoopPromise.succeed(Value)`
- `EventLoopPromise.fail(error: Error)` lost its label so is now `EventLoopPromise.fail(Error)`
- renamed `HTTPProtocolUpgrader` to `HTTPServerProtocolUpgrader`
- `ByteToMessageDecoder`s no longer automatically close the connection on error.
- `EventLoopFuture.cascade(promise: EventLoopPromise)` had its label changed to `EventLoopFuture.cascade(to: EventLoopPromise)`
- `EventLoopFuture.cascadeFailure(promise: EventLoopPromise)` had its label changed to `EventLoopFuture.cascade(to: EventLoopPromise)`
- renamed `EventLoopFuture.andAll(_:eventLoop:)` to `EventLoopFuture.andAllSucceed(_:on:)`
- all `ChannelPipeline.remove(...)` now return `EventLoopFuture<Void>` instead of `EventLoopFuture<Bool>`
- `ByteBuffer.set(<type>, ...)` is now `ByteBuffer.set<Type>`
- `ByteBuffer.write(<type>, ...)` is now `ByteBuffer.write<Type>`
- renamed `EventLoopFuture.hopTo(eventLoop:)` to `EventLoopFuture.hop(to:)`
- `EventLoopFuture.reduce(into:_:eventLoop:_:)` had its label signature changed to `EventLoopFuture.reduce(into:_:on:_:)`
- `EventLoopFuture.reduce(_:_:eventLoop:_:` had its label signature changed to `EventLoopFuture.reduce(_:_:on:_:)`
- `CircularBuffer` and `MarkedCircularBuffer`'s indices are now opaque
- all `ChannelOption`s are now required to be  `Equatable`
- rename `FileHandle` to `NIOFileHandle`
- rename all `ChannelPipeline.add(name:handler:...)`s to `ChannelPipeline.addHandler(_:name:...)`
- rename all `ChannelPipeline.remove(...)`s to `ChannelPipeline.removeHandler(...)`
- change `ChannelPipeline.addHandler[s](_:first:)` to  `ChannelPipeline.addHandler(_:postion:)` where `position` can be `.first`, `.last`, `.before(ChannelHandler)`, and `.after(ChannelHandler)`
- change  `ChannelPipeline.addHandler(_:before:)` to  `ChannelPipeline.addHandler(_:postion:)` where `position` can be `.first`, `.last`, `.before(ChannelHandler)`, and `.after(ChannelHandler)`
- change  `ChannelPipeline.addHandler(_:after:)` to  `ChannelPipeline.addHandler(_:postion:)` where `position` can be `.first`, `.last`, `.before(ChannelHandler)`, and `.after(ChannelHandler)`
