# NIO and Swift Concurrency

This article explains how to interface between NIO and Swift Concurrency 

NIO was created before native Concurrency support in Swift existed, hence, NIO had to solve
a few problems that have solutions in the language today. Since, the introduction of Swift Concurrency
NIO has added numerous features to make the inter-op between NIOs channel eventing system and Swift's
Concurrency primitives as easy as possible.

### EventLoopFuture bridges

The first bridges, that NIO introduced were adding methods on ``EventLoopFuture`` and ``EventLoopPromise``
to bridge to and from Concurrency. Namely these bridges are ``EventLoopFuture/get()`` and ``EventLoopPromise/completeWithTask(_:)``.

> Warning: The future ``EventLoopFuture/get()`` method does not support task cancellation.

Here is a small example of how these work:

```swift
let eventLoop: EventLoop

let promise = eventLoop.makePromise(of: Bool.self)

promise.completeWithTask {
    try await Task.sleep(for: .seconds(1))
    return true
}

let result = try await promise.futureResult.get()
```

> Note: The `completeWithTask` method is creating an unstructured task under the hood.

### Channel bridges

The ``EventLoopFuture`` and ``EventLoopPromise`` bridges already allow async code to interact with
some of NIO's types. However, they only work where we need to bridge request-response like interfaces.
On the other hand, NIO's' ``Channel`` type contains a ``ChannelPipeline`` which can be roughly 
described as a bi-directional streaming pipeline. To bridge such a pipeline into Concurrency required
new types. Importantly, these types need to uphold the channel's back-pressure and writability guarantees.
NIO introduced the ``NIOThrowingAsyncSequenceProducer``, ``NIOAsyncSequenceProducer`` and the ``NIOAsyncWriter``
which form the foundation to bridge a ``Channel``.
On top of these foundational types, NIO provides the `NIOAsyncChannel` which is used to wrap a 
``Channel`` to produce an interface that can be consumed directly from Swift Concurrency. The following
sections cover the details of the foundational types and how the `NIOAsyncChannel` works.

#### NIOThrowingAsyncSequenceProducer and NIOAsyncSequenceProducer

The ``NIOThrowingAsyncSequenceProducer`` and ``NIOAsyncSequenceProducer`` are root asynchronous sequences
similar to Swift's `AsyncStream`. Their core goal is to provide a back-pressured bridge between a
synchronous producer and an asynchronous consumer. These types are highly configurable and generic which
makes them usable in a lot of places with very good performance; however, at the same time they are
not the easiest types to hold. We recommend that you **never** expose them in public API but rather
wrap them in your own async sequence.

#### NIOAsyncWriter

The ``NIOAsyncWriter`` is used for bridging from an asynchronous producer to a synchronous consumer.
It also has back-pressure support which allows the synchronous side to suspend calls to the
``NIOAsyncWriter/yield(contentsOf:)`` method.


> Important: Everything below this is currently not public API but can be test it by using `@_spi(AsyncChannel) import`.
The APIs might change until they become publicly available.

#### NIOAsyncChannel

The above types are used to bridge both the read and write side of a ``Channel`` into Swift Concurrency.
This can be done by wrapping a ``Channel`` via the `NIOAsyncChannel/init(synchronouslyWrapping:backpressureStrategy:isOutboundHalfClosureEnabled:inboundType:outboundType:)`
initializer. Under the hood, this initializer adds two channel handlers to the end of the channel's pipeline.
These handlers bridge the read and write side of the channel. Additionally, the handlers are working together
to close the channel once both the reading and the writing have finished.


This is how you can wrap an existing channel into a `NIOAsyncChannel`, consume the inbound data and
echo it back outbound.

```swift
let channel = StringChannel()
let asyncChannel = try NIOAsyncChannel(synchronouslyWrapping: channel, inboundType: String.self, outboundType: String.self)

for try await inboundData in asyncChannel.inboundStream {
    try await asyncChannel.outboundWriter.write(inboundData)
}
```

### Async bootstrap

The `NIOAsyncChannel` alone would already allow you to wrap your channels and use them from Concurrency;
however, you must be very careful at what point you wrap your channel otherwise you might lose some reads.
Furthermore, with the introduction of `NIOAsyncChannel` we also recommend reevaluating where your
business logic lives and thinking about moving it from channel handlers into Concurrency tasks. A good split is
to put network protocol logic into channel handlers and business logic into tasks.
To solve the above timing problems and guide users into the Concurrency based solution the various bootstraps
gained new methods that directly return `NIOAsyncChannel`s.
Before diving into how these new bootstrap methods work there is one more problem that needs to be called out -
 Protocol Negotiation.

#### Protocol Negotiation

With the introduction of `NIOAsyncChannel` we are introducing concrete types to the channel's pipeline. The underlying
bridging handlers of the `NIOAsyncChannel` are generic and unwrap the inbound and wrap the outbound data.
This means that once you wrap a ``Channel`` into a `NIOAsyncChannel` the inbound and outbound types
need to be known. Moreover, these types are not allowed to change anymore otherwise it will result in
runtime crashes.
To solve the problem of protocol negotiation we had to introduce a new ``ChannelHandler`` protocol called
`NIOProtocolNegotiationHandler`. This protocol requires a single future property `NIOProtocolNegotiationHandler/protocolNegotiationResult`
that is completed once the handler is finished with protocol negotiation. In the successful case,
the future can either indicate that protocol negotiation is fully done by returning `NIOProtocolNegotiationResult/finished(_:)``or
indicate that further protocol negotiation needs to be done by returning `NIOProtocolNegotiationResult/deferredResult(_:)`.

#### ServerBootstrap

The server bootstrap is used to create a new TCP based server. Once any of the bind methods on the `ServerBootstrap`
is called, a new listening socket is created to handle new inbound TCP connections. Let's take a look
at the new `NIOAsyncChannel` based bind methods.

```swift
let serverChannel = try await ServerBootstrap(group: eventLoopGroup)
    .bind(
        host: "127.0.0.1",
        port: 0,
        childChannelInboundType: ByteBuffer.self,
        childChannelOutboundType: ByteBuffer.self
    )

    try await withThrowingDiscardingTaskGroup { group in
        for try await connectionChannel in serverChannel.inboundStream {
            group.addTask {
                do {
                    for try await inboundData in connectionChannel.inboundStream {
                        try await  connectionChannel.outboundWriter.write(inboundData)
                    }
                } catch {
                    // Handle errors
                }
            }
        }
    }
```

In the above code, we are bootstrapping a new TCP server which we assign to `serverChannel`. The type of 
`serverChannel` is a `NIOAsyncChannel` of `NIOAsyncChannel`. This is due to the fact that each
inbound connection gets its own separate child channel.
Afterward, we are handling each inbound connection in a separate child task and echo the data back.

> Important: Make sure to use discarding task groups which are automatically reaping finished child tasks.
Normal task groups will result in a memory leak since they do not reap their child tasks automatically.

The above works create for channels that do not have protocol negotiation handlers in their pipeline
since we can define the child channel's inbound and outbound type when calling `bind()`. In the case
of protocol negotiation, we have to use a different bind method since now the types of the child channels
are only known once protocol negotiation is done. Let's walk through how to setup a `ServerBootstrap`
with protocol negotiation.

First, we have to define our negotiation result. For this example, we are negotiating between a
`String` based and `UInt8` based channel. Additionally, we also need an error that we can throw
if protocol negotiation failed.
```swift
enum NegotiationResult {
    case string(NIOAsyncChannel<String, String>)
    case byte(NIOAsyncChannel<UInt8, UInt8>)
}

struct ProtocolNegotiationError: Error {}
```

Next, we have to setup our bootstrap. We are adding a `NIOTypedApplicationProtocolNegotiationHandler`
to each child channel's pipeline This handler is listening to user inbound events of the type `TLSUserEvent`
and then calls the provided closure with the result. In our example, we are handling either `string`
or `byte` application protocols. Importantly, we now have to wrap the channel into a `NIOAsyncChannel` ourselves and
return the finished `NIOProtocolNegotiationResult`.
```swift
let serverBoostrap = try await ServerBootstrap(group: eventLoopGroup)
    .childChannelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
            let negotiationHandler = NIOTypedApplicationProtocolNegotiationHandler<NegotiationResult>(eventLoop: channel.eventLoop) { alpnResult, channel in
                switch alpnResult {
                case .negotiated(let alpn):
                    switch alpn {
                    case "string":
                        return channel.eventLoop.makeCompletedFuture {
                            let asyncChannel = try NIOAsyncChannel(
                                synchronouslyWrapping: channel,
                                isOutboundHalfClosureEnabled: true,
                                inboundType: String.self,
                                outboundType: String.self
                            )

                            return NIOProtocolNegotiationResult.finished(NegotiationResult.string(asyncChannel))
                        }
                    case "byte":
                        return channel.eventLoop.makeCompletedFuture {
                            let asyncChannel = try NIOAsyncChannel(
                                synchronouslyWrapping: channel,
                                isOutboundHalfClosureEnabled: true,
                                inboundType: UInt8.self,
                                outboundType: UInt8.self
                            )

                            return NIOProtocolNegotiationResult.finished(NegotiationResult.byte(asyncChannel))
                        }
                    default:
                        return channel.eventLoop.makeFailedFuture(ProtocolNegotiationError())
                    }
                case .fallback:
                    return channel.eventLoop.makeFailedFuture(ProtocolNegotiationError())
                }
            }

            try channel.pipeline.syncOperations.addHandler(negotiationHandler)
        }
    }
```

Lastly, we can now bind the `serverChannel` and handle the incoming connections. In the code below,
you can see that our server channel is now a `NIOAsyncChannel` of `NegotiationResult`s instead of
child channels.
```swift
let serverChannel = serverBootstrap.bind(
    host: "127.0.0.1",
    port: 1995,
    protocolNegotiationHandlerType: NIOTypedApplicationProtocolNegotiationHandler<NegotiationResult>.self
)

try await withThrowingDiscardingTaskGroup { group in
    for try await negotiationResult in serverChannel.inboundStream {
        group.addTask {
            do {
                switch connectionChannel {
                case .string(let channel):
                    for try await value in channel.inboundStream {
                        continuation.yield(.string(value))
                    }
                case .byte(let channel):
                    for try await value in channel.inboundStream {
                        continuation.yield(.byte(value))
                    }   
                }
            }
        }
    }
}
```
