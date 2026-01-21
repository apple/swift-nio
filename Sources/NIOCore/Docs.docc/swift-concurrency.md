# NIO and Swift Concurrency

This article explains how to interface between NIO and Swift Concurrency.

NIO was created before native Concurrency support in Swift existed, hence, NIO
had to solve a few problems that have solutions in the language today. Since the
introduction of Swift Concurrency, NIO has added numerous features to make the
interop between NIO's ``Channel`` eventing system and Swift's Concurrency
primitives as easy as possible.

### EventLoopFuture/Promise bridges

The first bridges that NIO introduced added methods on ``EventLoopFuture`` and
``EventLoopPromise`` to enable communication between Concurrency and NIO. These
methods are ``EventLoopFuture/get()`` and
``EventLoopPromise/completeWithTask(_:)``.

> Warning: The future ``EventLoopFuture/get()`` method does not support task
> cancellation.

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

> Note: The `completeWithTask` method creates an unstructured task under the
> hood.

### Channel bridges

The ``EventLoopFuture`` and ``EventLoopPromise`` bridges already allow async
code to interact with some of NIO's types. However, they only work where we have
request-response-like interfaces. On the other hand, NIO's ``Channel`` type
contains a ``ChannelPipeline`` which can be roughly described as a
bi-directional streaming pipeline. To bridge such a pipeline into Concurrency
required new types. Importantly, these types need to uphold the channel's
back pressure and writability guarantees. NIO introduced the
``NIOThrowingAsyncSequenceProducer``, ``NIOAsyncSequenceProducer`` and the
``NIOAsyncChannelOutboundWriter`` which form the foundation to bridge a ``Channel``. On top of
these foundational types, NIO provides the `NIOAsyncChannel` which is used to
wrap a ``Channel`` to produce an interface that can be consumed directly from
Swift Concurrency. The following sections cover the details of the foundational
types and how the `NIOAsyncChannel` works.

#### NIOThrowingAsyncSequenceProducer and NIOAsyncSequenceProducer

The ``NIOThrowingAsyncSequenceProducer`` and ``NIOAsyncSequenceProducer`` are
asynchronous sequences similar to Swift's `AsyncStream`. Their purpose is to
provide a back pressured bridge between a synchronous producer and an
asynchronous consumer. These types are highly configurable and generic which
makes them usable in a lot of places with very good performance; however, at the
same time they are not the easiest types to hold. We recommend that you
**never** expose them in public API but rather wrap them in your own async
sequence.

#### NIOAsyncWriter

The ``NIOAsyncChannelOutboundWriter`` is used for bridging from an asynchronous producer to a
synchronous consumer. It also has back pressure support which allows the
consumer to stop the producer by suspending the
``NIOAsyncWriter/yield(contentsOf:)`` method.

#### NIOAsyncChannel

The above types are used to bridge both the read and write side of a ``Channel``
into Swift Concurrency. This can be done by wrapping a ``Channel`` via the
`NIOAsyncChannel/init(synchronouslyWrapping:configuration:)`
initializer. Under the hood, this initializer adds two channel handlers to the
end of the channel's pipeline. These handlers bridge the read and write side of
the channel. Additionally, the handlers work together to close the channel once
both the reading and the writing have finished.

This is how you can wrap an existing channel into a `NIOAsyncChannel`, consume
the inbound data and echo it back outbound.

```swift
let channel = ...
let asyncChannel = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)

try await asyncChannel.executeThenClose { inbound, outbound in
    for try await inboundData in inbound {
        try await outbound.write(inboundData)
    }
}
```

The above code works nicely; however, you must be very careful at what point you
wrap your channel otherwise you might lose some reads. For example your channel
might be created by a `ServerBootstrap` for a new inbound connection. The
channel might start to produce reads as soon as it registered its IO which
happens after your channel initializer ran. To avoid potentially losing reads
the channel must be wrapped before it registered its IO. Another example is when
the channel contains a handler that does protocol negotiation. Protocol
negotiation handlers are usually waiting for some data to be exchanged before
deciding what protocol to chose. Afterwards, they often modify the channel's
pipeline and add the protocol appropriate handlers to it. This is another case
where wrapping of the `Channel` into a `NIOAsyncChannel` needs to happen at the
right time to avoid losing reads.

### Asynchronous bootstrap methods

NIO offers a multitude of bootstraps. To avoid the above problems
and enable a seamless experience when using NIO from Swift Concurrency,
the bootstraps gained new generic asynchronous methods.

The next section is going to focus on how to use the methods to boostrap a TCP
server and client.

#### ServerBootstrap

The server bootstrap is used to create a new TCP based server. Once any of the
bind methods on the `ServerBootstrap` is called, a new listening socket is
created to handle new inbound TCP connections. Let's use the new methods
to setup a TCP server and configure a `NIOAsyncChannel` for each inbound
connection.

```swift
let serverChannel = try await ServerBootstrap(group: eventLoopGroup)
    .bind(
        host: "127.0.0.1",
        port: 1234
    ) { childChannel in
        // This closure is called for every inbound connection
        childChannel.eventLoop.makeCompletedFuture {
            return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                synchronouslyWrapping: childChannel
            )
        }
    }

try await withThrowingDiscardingTaskGroup { group in
    try await serverChannel.executeThenClose { serverChannelInbound in
        for try await connectionChannel in serverChannelInbound {
            group.addTask {
                do {
                    try await connectionChannel.executeThenClose { connectionChannelInbound, connectionChannelOutbound in
                        for try await inboundData in connectionChannelInbound {
                            // Let's echo back all inbound data
                            try await connectionChannelOutbound.write(inboundData)
                        }
                    }
                } catch {
                    // Handle errors
                }
            }
        }
    }
}
```

In the above code, we are bootstrapping a new TCP server which we assign to
`serverChannel`. Furthermore, in the trailing closure of `bind` we are
configuring the pipeline of each inbound connection. In our example, we are
wrapping each child channel in a `NIOAsyncChannel`. The resulting
`serverChannel` is a `NIOAsyncChannel` whose inbound type is a `NIOAsyncChannel`
and  whose outbound type is `Never`. This is due to the fact that each inbound
connection gets its own separate child channel. The inbound and outbound types
of each inbound connection is `ByteBuffer` as specified in the bootstrap.
Afterwards, we handle each inbound connection in separate child tasks and echo
the data back.

> Important: Make sure to use discarding task groups which automatically reap
finished child tasks. Normal task groups will result in a memory leak since they
do not reap their child tasks automatically.

#### ClientBootstrap

The client bootstrap is used to create a new TCP based client. Let's take a look
how to bootstrap a TCP connection and send some data to the server.

```swift
let clientChannel = try await ClientBootstrap(group: eventLoopGroup)
    .connect(
        host: "127.0.0.1",
        port: 1234
    ) { channel in
        channel.eventLoop.makeCompletedFuture {
            return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                wrappingChannelSynchronously: channel
            )
        }
    }

try await clientChannel.executeThenClose { inbound, outbound in
    try await outbound.write(ByteBuffer(string: "hello"))

    for try await inboundData in inbound {
        print(inboundData)
    }
}
```

#### Dynamic pipeline modifications

The above bootstrap methods work great in the case where we know the types of
the resulting channels at compile time. However, there are some scenarios where
the type is only determined at runtime. Such cases include
[Application-Layer-Protocol-Negotiation](https://en.wikipedia.org/wiki/Application-Layer_Protocol_Negotiation)
or [HTTP protocol
upgrades](https://en.wikipedia.org/wiki/HTTP/1.1_Upgrade_header). To support
those scenarios it is essential that channel handlers that dynamically configure
the pipeline carry type information which allows us to runtime to determine how
the pipeline was configured at runtime. To support this NIO introduced multiple
new `ChannelHandler` and corresponding pipeline configuration methods. Those
types are:

1. `NIOTypedApplicationProtocolNegotiationHandler` for TLS based ALPN
2. `NIOTypedHTTPServerUpgradeHandler` and
   `configureUpgradableHTTPServerPipeline` for server-side HTTP protocol
   upgrades
2. `NIOTypedHTTPClientUpgradeHandler` and
   `configureUpgradableHTTPClientPipeline` for client-side HTTP protocol
   upgrades

All of those types have one thing in common - they are generic over the result
of the dynamic pipeline configuration. This allows users to exhaustively switch
over the result and correctly handle each case. The following example
demonstrates how this works for a client-side websocket upgrade.

```swift
enum UpgradeResult {
    case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
    case notUpgraded
}

let upgradeResult: EventLoopFuture<UpgradeResult> = try await ClientBootstrap(group: eventLoopGroup)
    .connect(
        host: "127.0.0.1",
        port: 1234
    ) { channel in
        channel.eventLoop.makeCompletedFuture {
            // Configure the websocket upgrader
            let upgrader = NIOTypedWebSocketClientUpgrader<UpgradeResult>(
                upgradePipelineHandler: { channel, _ in
                    // This configures the pipeline after the websocket upgrade was successful.
                    // We are wrapping the pipeline in a NIOAsyncChannel.
                    channel.eventLoop.makeCompletedFuture {
                        let asyncChannel = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(wrappingChannelSynchronously: channel)
                        return UpgradeResult.websocket(asyncChannel)
                    }
                }
            )

            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
            headers.add(name: "Content-Length", value: "0")

            let requestHead = HTTPRequestHead(
                version: .http1_1,
                method: .GET,
                uri: "/",
                headers: headers
            )

            let clientUpgradeConfiguration = NIOTypedHTTPClientUpgradeConfiguration(
                upgradeRequestHead: requestHead,
                upgraders: [upgrader],
                notUpgradingCompletionHandler: { channel in
                    channel.eventLoop.makeCompletedFuture {
                        return UpgradeResult.notUpgraded
                    }
                }
            )

            let upgradeResult = try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(
                configuration: .init(upgradeConfiguration: clientUpgradeConfiguration)
            )

            return upgradeResult
        }
    }
```

After having configured the pipeline to negotiate a websocket upgrade. We can
switch over the the `upgradeResult`. Importantly, we have to `await` the
`upgradeResult` first since it has to be negotiated on the connection.

```
switch try await upgradeResult.get() {
case .websocket(let websocketChannel):
    print("Handling websocket connection")
    try await self.handleWebsocketChannel(websocketChannel)
    print("Done handling websocket connection")
case .notUpgraded:
    // The upgrade to websocket did not succeed.
    print("Upgrade declined")
}
```

### NIOAny

In NIO 2.77.0, a number of methods that took `NIOAny` as a parameter started
emitting deprecation warnings. These deprecation warnings are a substitute for the
concurrency warnings that you might otherwise see.

The problem with these methods (most of which were defined on ``ChannelInvoker``)
is that they frequently would send a `NIOAny` across an event loop boundary.
Most commonly users will encounter this when calling methods on ``Channel`` types
(which conform to ``ChannelInvoker``), though they may encounter it on
``ChannelPipeline`` as well.

The problem these methods have is that they can be safely called both on and off
of the ``EventLoop`` to which a ``Channel`` is bound. That means that they must be
capable of sending the value across an isolation domain, into the ``EventLoop``.
That requires the parameter to be `Sendable` (or to be `sending`).

`NIOAny` cannot be made to be `Sendable`, so these methods are now deprecated.
They have been replaced with equivalent methods that take a generic type that
must be `Sendable`, and they take charge of wrapping the type in `NIOAny`. If
you encounter such a warning, this is the most common change.

In cases where a non-`Sendable` value must actually be sent into the pipeline, there
are a few methods that can still be used. These methods are available on
``ChannelPipeline/SynchronousOperations``, which can be accessed via
``ChannelPipeline/syncOperations``. The ``ChannelPipeline/SynchronousOperations`` type
can only be accessed from on the `EventLoop`, and so no sending of a value
across isolation domains will occur here.

### General guidance

#### Where should your code live?

Before the introduction of Swift Concurrency both implementations of network
protocols and business logic were often written inside ``ChannelHandler``s. This
made it easier to get started; however, it came with some downsides. First,
implementing business logic inside channel handlers requires the business logic
to also handle all of the invariants that the ``ChannelHandler`` protocol brings
with it. This often requires writing complex state machines. Additionally, the
business logic becomes very tied to NIO and hard to port between different
systems. Because of the above reasons we recommend to implement your business
logic using Swift Concurrency primitives and the `NIOAsyncChannel` based
bootstraps. Network protocol implementation should still be implemented as
``ChannelHandler``s.
