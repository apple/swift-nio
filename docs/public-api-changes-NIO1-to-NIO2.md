# Changes in the Public API from NIO 1 to NIO 2

- removed all previously deprecated functions, types and modules.
- renamed `SniResult` to `SNIResult`
- renamed `SniHandler` to `SNIHandler`
- made `EventLoopGroup.makeIterator()` a required method
- `TimeAmount.Value` is now `Int64` (from `Int` on 64 bit platforms, no change
  for 32 bit platforms)
- `ByteToMessageDecoder`s now need to be wrapped in `ByteToMessageHandler`
  before they can be added to the pipeline.
  before: `pipeline.add(MyDecoder())`, after: `pipeline.add(ByteToMessageHandler(MyDecoder()))`
- `EventLoop.makePromise`/`makeSucceededFuture`/`makeFailedFuture` instead of `new*`
- `SocketAddress.makeAddressResolvingHost(:port:)` instead of
  `SocketAddress.newAddressResolving(host:port:)`
- changed all ports to `Int` (from `UInt16`)
- changed `HTTPVersion`'s `major` and `minor` properties to `Int` (from `UInt16`)
- renamed the generic parameter name to `Bytes` where we're talking about a
  generic collection of bytes
- Moved error `ChannelLifecycleError.inappropriateOperationForState` to `ChannelError.inappropriateOperationForState`.
- Moved all errors in `MulticastError` enum into `ChannelError`.
- Removed `ChannelError.connectFailed`. All errors that triggered this now throw `NIOConnectError` directly.
