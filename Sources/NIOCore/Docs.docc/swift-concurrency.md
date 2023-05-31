# NIO and Swift Concurrency

This article explains how to interface between NIO and Swift Concurrency.

NIO was created before native Concurrency support in Swift existed, hence, NIO had to solve
a few problems that have solutions in the language today. Since the introduction of Swift Concurrency,
NIO has added numerous features to make the interop between NIO's ``Channel`` eventing system and Swift's
Concurrency primitives as easy as possible.

### EventLoopFuture bridges

The first bridges that NIO introduced added methods on ``EventLoopFuture`` and ``EventLoopPromise``
to enable communication between Concurrency and NIO. These methods are ``EventLoopFuture/get()`` and ``EventLoopPromise/completeWithTask(_:)``.

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

> Note: The `completeWithTask` method creates an unstructured task under the hood.

### Channel bridges

The ``EventLoopFuture`` and ``EventLoopPromise`` bridges already allow async code to interact with
some of NIO's types. However, they only work where we have request-response-like interfaces.
On the other hand, NIO's ``Channel`` type contains a ``ChannelPipeline`` which can be roughly 
described as a bi-directional streaming pipeline. To bridge such a pipeline into Concurrency required
new types. Importantly, these types need to uphold the channel's back-pressure and writability guarantees.
NIO introduced the ``NIOThrowingAsyncSequenceProducer``, ``NIOAsyncSequenceProducer`` and the ``NIOAsyncWriter``
which form the foundation to bridge a ``Channel``.
On top of these foundational types, NIO provides the `NIOAsyncChannel` which is used to wrap a 
``Channel`` to produce an interface that can be consumed directly from Swift Concurrency. The following
sections cover the details of the foundational types and how the `NIOAsyncChannel` works.

#### NIOThrowingAsyncSequenceProducer and NIOAsyncSequenceProducer

The ``NIOThrowingAsyncSequenceProducer`` and ``NIOAsyncSequenceProducer`` are asynchronous sequences
similar to Swift's `AsyncStream`. Their purpose is to provide a back-pressured bridge between a
synchronous producer and an asynchronous consumer. These types are highly configurable and generic which
makes them usable in a lot of places with very good performance; however, at the same time they are
not the easiest types to hold. We recommend that you **never** expose them in public API but rather
wrap them in your own async sequence.

#### NIOAsyncWriter

The ``NIOAsyncWriter`` is used for bridging from an asynchronous producer to a synchronous consumer.
It also has back-pressure support which allows the consumer to stop the producer by suspending the
``NIOAsyncWriter/yield(contentsOf:)`` method.


> Important: Everything below this is currently not public API but can be tested it by using `@_spi(AsyncChannel) import`.
The APIs might change until they become publicly available.

#### NIOAsyncChannel

The above types are used to bridge both the read and write side of a ``Channel`` into Swift Concurrency.
This can be done by wrapping a ``Channel`` via the `NIOAsyncChannel/init(synchronouslyWrapping:backpressureStrategy:isOutboundHalfClosureEnabled:inboundType:outboundType:)`
initializer. Under the hood, this initializer adds two channel handlers to the end of the channel's pipeline.
These handlers bridge the read and write side of the channel. Additionally, the handlers work together
to close the channel once both the reading and the writing have finished.


This is how you can wrap an existing channel into a `NIOAsyncChannel`, consume the inbound data and
echo it back outbound.

```swift
let channel = ...
let asyncChannel = try NIOAsyncChannel(synchronouslyWrapping: channel, inboundType: ByteBuffer.self, outboundType: ByteBuffer.self)

for try await inboundData in asyncChannel.inboundStream {
    try await asyncChannel.outboundWriter.write(inboundData)
}
```

The above code works nicely; however, you must be very careful at what point you wrap your channel
otherwise you might lose some reads. For example your channel might be created by a `ServerBootstrap`
for a new inbound connection. The channel might start to produce reads as soon as it registered its
IO which happens after your channel initializer ran. To avoid potentially losing reads the channel
must be wrapped before it registered its IO.
Another example is when the channel contains a handler that does protocol negotiation. Protocol negotiation handlers
are usually waiting for some data to be exchanged before deciding what protocol to chose. Afterwards, they
often modify the channel's pipeline and add the protocol appropriate handlers to it. This is another
case where wrapping of the `Channel` into a `NIOAsyncChannel` needs to happen at the right time to avoid
losing reads.

### Async bootstrap

NIO offers three different kind of bootstraps `ServerBootstrap`, `ClientBootstrap` and `DatagramBootstrap`.
The next section is going to focus on how to use the methods of these three types to bootstrap connections
using `NIOAsyncChannel`.


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
                    try await connectionChannel.outboundWriter.write(inboundData)
                }
            } catch {
                // Handle errors
            }
        }
    }
}
```

In the above code, we are bootstrapping a new TCP server which we assign to `serverChannel`.
The `serverChannel` is a `NIOAsyncChannel` whose inbound type is a `NIOAsyncChannel` and  whose 
outbound type is `Never`. This is due to the fact that each inbound connection gets its own separate child channel.
The inbound and outbound types of each inbound connection is `ByteBuffer` as specified in the bootstrap.
Afterwards, we handle each inbound connection in separate child tasks and echo the data back.

> Important: Make sure to use discarding task groups which automatically reap finished child tasks.
Normal task groups will result in a memory leak since they do not reap their child tasks automatically.

#### ClientBootstrap
> Important: Support for `ClientBootstrap` with `NIOAsyncChannel` hasn't landed yet.

#### DatagramBootstrap
> Important: Support for `DatagramBootstrap` with `NIOAsyncChannel` hasn't landed yet.

#### Protocol negotiation

The above bootstrap methods work great in the case where we know the types of the resulting channels
at compile time. However, as mentioned previously protocol negotiation is another case where the timing
of wrapping the ``Channel`` is important that we haven't covered with the `bind` methods that take
an inbound and outbound type yet.
To solve the problem of protocol negotiation, NIO introduced a new ``ChannelHandler`` protocol called
`NIOProtocolNegotiationHandler`. This protocol requires a single future property `NIOProtocolNegotiationHandler/protocolNegotiationResult`
that is completed once the handler is finished with protocol negotiation. In the successful case,
the future can either indicate that protocol negotiation is fully done by returning `NIOProtocolNegotiationResult/finished(_:)` or
indicate that further protocol negotiation needs to be done by returning `NIOProtocolNegotiationResult/deferredResult(_:)`.
Additionally, the various bootstraps provide another set of `bind()` methods that handle protocol negotiation.
Let's walk through how to setup a `ServerBootstrap` with protocol negotiation.

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
to each child channel's pipeline. This handler listens for user inbound events of the type `TLSUserEvent`
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
                switch negotiationResult {
                case .string(let channel):
                    for try await inboundData in channel.inboundStream {
                        try await channel.outboundWriter.write(inboundData)
                    }
                case .byte(let channel):
                    for try await value in channel.inboundStream {
                        try await channel.outboundWriter.write(inboundData)
                    }   
                }
            } catch {
                // Handle errors
            }
        }
    }
}
```


### General guidance

#### Where should your code live?

Before the introduction of Swift Concurrency both implementations of network protocols and business logic
were often written inside ``ChannelHandler``s. This made it easier to get started; however, it came with
some downsides. First, implementing business logic inside channel handlers requires the business logic to
also handle all of the invariants that the ``ChannelHandler`` protocol brings with it. This often requires
writing complex state machines. Additionally, the business logic becomes very tied to NIO and hard to
port between different systems.
Because of the above reasons we recommend to implement your business logic using Swift Concurrency primitives and the
`NIOAsyncChannel` based bootstraps. Network protocol implementation should still be implemented as
``ChannelHandler``s.
