# Async NIO bridges

This is a summary of all the new APIs we introduced to make NIO and the various
network protocols work with new async interfaces. The intention of this document
is to quickly outline the incompatibilities in the original API and then show a
holistic view over all the new APIs.

## What APIs are needed?

The first problem that we had to tackle was bridging NIO's `Channel` to Swift
Concurrency. To do so we introduced two new foundational types - the
`NIOAsyncSequenceProducer` and the `NIOAsyncWriter`. Those allow us to bridge
the read and the write side of the `Channel` while propagating the back-pressure
across the bridge.

On top of those two types, we built out the `NIOAsyncChannel` which allows users
to bridge a `Channel` into Swift Concurrency. To do this it inserts two channel
handlers which bridge the read and write side using the
`NIOAsyncSequenceProducer` and the `NIOAsyncWriter`.

Next up we had to look at the bootstraps. Here the import part is that the
`Channel`s **must** be wrapped at the correct timing otherwise there is the
potential that reads might be dropped. This is not problematic for most of the
bootstraps since they call their various `channelInitializer`s and
`childChannelInitializer`s at the right time. However, there was one tricky
bootstrap - `ServerBootstrap`. The `ServerBootstrap` multiplexes the incoming
connections and we have to make sure that the wrapping of the child channels
happens at the correct time. Additionally, the new bootstrap APIs **must** be
able to relay the type information of the configured channels to the
`bind`/`connect` methods.

The next thing we had to tackle was networking protocols that dynamically
re-configure the `ChannelPipeline`. The two examples that we provide
implementations for are HTTP/1 protocol upgrades and Application Protocol
Negotiation (ALPN) via TLS. Similar to the bootstraps we have to ensure that the
type information is retained so that users can correctly identify which
reconfiguration path has been taken.

Lastly, we had to look at how to handle protocols that multiplex, like HTTP/2.
Multiplexing protocols need to expose a typed async interface to consume new
inbound connections/streams and to open new outbound connections/streams where
applicable.

## Proposed APIs

This section contains all the new APIs that we are adding and gives us a holistic
overview to review them.

### `NIOAsyncChannel`

```swift
/// Wraps a NIO ``Channel`` object into a form suitable for use in Swift Concurrency.
///
/// ``NIOAsyncChannel`` abstracts the notion of a NIO ``Channel`` into something that
/// can safely be used in a structured concurrency context. In particular, this exposes
/// the following functionality:
///
/// - reads are presented as an `AsyncSequence`
/// - writes can be written to with async functions on a writer, providing back pressure
/// - channels can be closed seamlessly
///
/// This type does not replace the full complexity of NIO's ``Channel``. In particular, it
/// does not expose the following functionality:
///
/// - user events
/// - traditional NIO back pressure such as writability signals and the ``Channel/read()`` call
///
/// Users are encouraged to separate their ``ChannelHandler``s into those that implement
/// protocol-specific logic (such as parsers and encoders) and those that implement business
/// logic. Protocol-specific logic should be implemented as a ``ChannelHandler``, while business
/// logic should use ``NIOAsyncChannel`` to consume and produce data to the network.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct NIOAsyncChannel<Inbound, Outbound> : Sendable where Inbound : Sendable, Outbound : Sendable {
    public struct Configuration : Sendable {
        /// The back pressure strategy of the ``NIOAsyncChannel/inbound``.
        public var backPressureStrategy: NIOCore.NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark

        /// If outbound half closure should be enabled. Outbound half closure is triggered once
        /// the ``NIOAsyncChannelOutboundWriter`` is either finished or deinitialized.
        public var isOutboundHalfClosureEnabled: Bool

        /// The ``NIOAsyncChannel/inbound`` message's type.
        public var inboundType: Inbound.Type

        /// The ``NIOAsyncChannel/outbound`` message's type.
        public var outboundType: Outbound.Type

        /// Initializes a new ``NIOAsyncChannel/Configuration``.
        ///
        /// - Parameters:
        ///   - backPressureStrategy: The back pressure strategy of the ``NIOAsyncChannel/inbound``. Defaults
        ///     to a watermarked strategy (lowWatermark: 2, highWatermark: 10).
        ///   - isOutboundHalfClosureEnabled: If outbound half closure should be enabled. Outbound half closure is triggered once
        ///     the ``NIOAsyncChannelOutboundWriter`` is either finished or deinitialized. Defaults to `false`.
        ///   - inboundType: The ``NIOAsyncChannel/inbound`` message's type.
        ///   - outboundType: The ``NIOAsyncChannel/outbound`` message's type.
        public init(backPressureStrategy: NIOCore.NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark = .init(lowWatermark: 2, highWatermark: 10), isOutboundHalfClosureEnabled: Bool = false, inboundType: Inbound.Type = Inbound.self, outboundType: Outbound.Type = Outbound.self)
    }

    /// The underlying channel being wrapped by this ``NIOAsyncChannel``.
    public let channel: NIOCore.Channel

    /// The stream of inbound messages.
    ///
    /// - Important: The `inbound` stream is a unicast `AsyncSequence` and only one iterator can be created.
    public let inbound: NIOCore.NIOAsyncChannelInboundStream<Inbound>

    /// The writer for writing outbound messages.
    public let outbound: NIOCore.NIOAsyncChannelOutboundWriter<Outbound>

    /// Initializes a new ``NIOAsyncChannel`` wrapping a ``Channel``.
    ///
    /// - Important: This **must** be called on the channel's event loop otherwise this init will crash. This is necessary because
    /// we must install the handlers before any other event in the pipeline happens otherwise we might drop reads.
    ///
    /// - Parameters:
    ///   - channel: The ``Channel`` to wrap.
    ///   - configuration: The ``NIOAsyncChannel``s configuration.
    @inlinable public init(synchronouslyWrapping channel: NIOCore.Channel, configuration: NIOCore.NIOAsyncChannel<Inbound, Outbound>.Configuration = .init()) throws

    /// Initializes a new ``NIOAsyncChannel`` wrapping a ``Channel`` where the outbound type is `Never`.
    ///
    /// This initializer will finish the ``NIOAsyncChannel/outboundWriter`` immediately.
    ///
    /// - Important: This **must** be called on the channel's event loop otherwise this init will crash. This is necessary because
    /// we must install the handlers before any other event in the pipeline happens otherwise we might drop reads.
    ///
    /// - Parameters:
    ///   - channel: The ``Channel`` to wrap.
    ///   - configuration: The ``NIOAsyncChannel``s configuration.
    @inlinable public init(synchronouslyWrapping channel: NIOCore.Channel, configuration: NIOCore.NIOAsyncChannel<Inbound, Outbound>.Configuration = .init()) throws where Outbound == Never

    /// This method is only used from our server bootstrap to allow us to run the child channel initializer
    /// at the right moment.
    ///
    /// - Important: This is not considered stable API and should not be used.
    @inlinable public static func _wrapAsyncChannelWithTransformations(synchronouslyWrapping channel: NIOCore.Channel, backPressureStrategy: NIOCore.NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil, isOutboundHalfClosureEnabled: Bool = false, channelReadTransformation: @escaping @Sendable (NIOCore.Channel) -> NIOCore.EventLoopFuture<Inbound>) throws -> NIOCore.NIOAsyncChannel<Inbound, Outbound> where Outbound == Never
}

/// The inbound message asynchronous sequence of a ``NIOAsyncChannel``.
///
/// This is a unicast async sequence that allows a single iterator to be created.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct NIOAsyncChannelInboundStream<Inbound> : Sendable where Inbound : Sendable {
    /// A source used for driving a ``NIOAsyncChannelInboundStream`` during tests.
    public struct TestSource {
        /// Yields the element to the inbound stream.
        ///
        /// - Parameter element: The element to yield to the inbound stream.
        @inlinable public func yield(_ element: Inbound)

        /// Finished the inbound stream.
        ///
        /// - Parameter error: The error to throw, or nil, to finish normally.
        @inlinable public func finish(throwing error: Error? = nil)
    }

    /// Creates a new stream with a source for testing.
    ///
    /// This is useful for writing unit tests where you want to drive a ``NIOAsyncChannelInboundStream``.
    ///
    /// - Returns: A tuple containing the input stream and a test source to drive it.
    @inlinable public static func makeTestingStream() -> (NIOCore.NIOAsyncChannelInboundStream<Inbound>, NIOCore.NIOAsyncChannelInboundStream<Inbound>.TestSource)
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncChannelInboundStream : AsyncSequence {
    /// The type of element produced by this asynchronous sequence.
    public typealias Element = Inbound

    /// The type of asynchronous iterator that produces elements of this
    /// asynchronous sequence.
    public struct AsyncIterator : AsyncIteratorProtocol {
        /// Asynchronously advances to the next element and returns it, or ends the
        /// sequence if there is no next element.
        /// 
        /// - Returns: The next element, if it exists, or `nil` to signal the end of
        ///   the sequence.
        @inlinable public mutating func next() async throws -> NIOCore.NIOAsyncChannelInboundStream<Inbound>.Element?
    }

    /// Creates the asynchronous iterator that produces elements of this
    /// asynchronous sequence.
    ///
    /// - Returns: An instance of the `AsyncIterator` type used to produce
    /// elements of the asynchronous sequence.
    @inlinable public func makeAsyncIterator() -> NIOCore.NIOAsyncChannelInboundStream<Inbound>.AsyncIterator
}

/// A ``NIOAsyncChannelOutboundWriter`` is used to write and flush new outbound messages in a channel.
///
/// The writer acts as a bridge between the Concurrency and NIO world. It allows to write and flush messages into the
/// underlying ``Channel``. Furthermore, it respects back-pressure of the channel by suspending the calls to write until
/// the channel becomes writable again.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct NIOAsyncChannelOutboundWriter<OutboundOut> : Sendable where OutboundOut : Sendable {
    /// An `AsyncSequence` backing a ``NIOAsyncChannelOutboundWriter`` for testing purposes.
    public struct TestSink : AsyncSequence {
        /// The type of element produced by this asynchronous sequence.
        public typealias Element = OutboundOut

        /// Creates the asynchronous iterator that produces elements of this
        /// asynchronous sequence.
        ///
        /// - Returns: An instance of the `AsyncIterator` type used to produce
        /// elements of the asynchronous sequence.
        public func makeAsyncIterator() -> NIOCore.NIOAsyncChannelOutboundWriter<OutboundOut>.TestSink.AsyncIterator

        /// The type of asynchronous iterator that produces elements of this
        /// asynchronous sequence.
        public struct AsyncIterator : AsyncIteratorProtocol {
            /// Asynchronously advances to the next element and returns it, or ends the
            /// sequence if there is no next element.
            /// 
            /// - Returns: The next element, if it exists, or `nil` to signal the end of
            ///   the sequence.
            public mutating func next() async -> NIOCore.NIOAsyncChannelOutboundWriter<OutboundOut>.TestSink.Element?
        }
    }

    /// Creates a new ``NIOAsyncChannelOutboundWriter`` backed by a ``NIOAsyncChannelOutboundWriter/TestSink``.
    /// This is mostly useful for testing purposes where one wants to observe the written data.
    @inlinable public static func makeTestingWriter() -> (NIOCore.NIOAsyncChannelOutboundWriter<OutboundOut>, NIOCore.NIOAsyncChannelOutboundWriter<OutboundOut>.TestSink)

    /// Send a write into the ``ChannelPipeline`` and flush it right away.
    ///
    /// This method suspends if the underlying channel is not writable and will resume once the it becomes writable again.
    @inlinable public func write(_ data: OutboundOut) async throws

    /// Send a sequence of writes into the ``ChannelPipeline`` and flush them right away.
    ///
    /// This method suspends if the underlying channel is not writable and will resume once the it becomes writable again.
    @inlinable public func write<Writes>(contentsOf sequence: Writes) async throws where OutboundOut == Writes.Element, Writes : Sequence

    /// Send an asynchronous sequence of writes into the ``ChannelPipeline``.
    ///
    /// This will flush after every write.
    ///
    /// This method suspends if the underlying channel is not writable and will resume once the it becomes writable again.
    @inlinable public func write<Writes>(contentsOf sequence: Writes) async throws where OutboundOut == Writes.Element, Writes : AsyncSequence

    /// Finishes the writer.
    ///
    /// This might trigger a half closure if the ``NIOAsyncChannel`` was configured to support it.
    public func finish()
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncChannelOutboundWriter.TestSink : Sendable {}
```

### Bootstraps

```swift
extension ClientBootstrap {
    /// Specify the `host` and `port` to connect to for the TCP `Channel` that will be established.
    ///
    /// - Parameters:
    ///   - host: The host to connect to.
    ///   - port: The port to connect to.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func connect<Output>(host: String, port: Int, channelInitializer: @escaping @Sendable (NIOCore.Channel) -> NIOCore.EventLoopFuture<Output>) async throws -> Output where Output : Sendable

    /// Specify the `address` to connect to for the TCP `Channel` that will be established.
    ///
    /// - Parameters:
    ///   - address: The address to connect to.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func connect<Output>(to address: NIOCore.SocketAddress, channelInitializer: @escaping @Sendable (NIOCore.Channel) -> NIOCore.EventLoopFuture<Output>) async throws -> Output where Output : Sendable

    /// Specify the `unixDomainSocket` path to connect to for the UDS `Channel` that will be established.
    ///
    /// - Parameters:
    ///   - unixDomainSocketPath: The _Unix domain socket_ path to connect to.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func connect<Output>(unixDomainSocketPath: String, channelInitializer: @escaping @Sendable (NIOCore.Channel) -> NIOCore.EventLoopFuture<Output>) async throws -> Output where Output : Sendable

    /// Use the existing connected socket file descriptor.
    ///
    /// - Parameters:
    ///   - descriptor: The _Unix file descriptor_ representing the connected stream socket.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func withConnectedSocket<Output>(_ socket: NIOCore.NIOBSDSocket.Handle, channelInitializer: @escaping @Sendable (NIOCore.Channel) -> NIOCore.EventLoopFuture<Output>) async throws -> Output where Output : Sendable
}

extension ServerBootstrap {
    /// Bind the `ServerSocketChannel` to the `host` and `port` parameters.
    ///
    /// - Parameters:
    ///   - host: The host to bind on.
    ///   - port: The port to bind on.
    ///   - serverBackPressureStrategy: The back pressure strategy used by the server socket channel.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func bind<Output>(host: String, port: Int, serverBackPressureStrategy: NIOCore.NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil, childChannelInitializer: @escaping @Sendable (NIOCore.Channel) -> NIOCore.EventLoopFuture<Output>) async throws -> NIOCore.NIOAsyncChannel<Output, Never> where Output : Sendable

    /// Bind the `ServerSocketChannel` to the `address` parameter.
    ///
    /// - Parameters:
    ///   - address: The `SocketAddress` to bind on.
    ///   - serverBackPressureStrategy: The back pressure strategy used by the server socket channel.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func bind<Output>(to address: NIOCore.SocketAddress, serverBackPressureStrategy: NIOCore.NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil, childChannelInitializer: @escaping @Sendable (NIOCore.Channel) -> NIOCore.EventLoopFuture<Output>) async throws -> NIOCore.NIOAsyncChannel<Output, Never> where Output : Sendable

    /// Bind the `ServerSocketChannel` to a UNIX Domain Socket.
    ///
    /// - Parameters:
    ///   - unixDomainSocketPath: The path of the UNIX Domain Socket to bind on. The`unixDomainSocketPath` must not exist,
    ///     unless `cleanupExistingSocketFile`is set to `true`.
    ///   - cleanupExistingSocketFile: Whether to cleanup an existing socket file at `unixDomainSocketPath`.
    ///   - serverBackPressureStrategy: The back pressure strategy used by the server socket channel.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func bind<Output>(unixDomainSocketPath: String, cleanupExistingSocketFile: Bool = false, serverBackPressureStrategy: NIOCore.NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil, childChannelInitializer: @escaping @Sendable (NIOCore.Channel) -> NIOCore.EventLoopFuture<Output>) async throws -> NIOCore.NIOAsyncChannel<Output, Never> where Output : Sendable

    /// Use the existing bound socket file descriptor.
    ///
    /// - Parameters:
    ///   - socket: The _Unix file descriptor_ representing the bound stream socket.
    ///   - serverBackPressureStrategy: The back pressure strategy used by the server socket channel.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func bind<Output>(_ socket: NIOCore.NIOBSDSocket.Handle, cleanupExistingSocketFile: Bool = false, serverBackPressureStrategy: NIOCore.NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil, childChannelInitializer: @escaping @Sendable (NIOCore.Channel) -> NIOCore.EventLoopFuture<Output>) async throws -> NIOCore.NIOAsyncChannel<Output, Never> where Output : Sendable
}

extension DatagramBootstrap {
    /// Use the existing bound socket file descriptor.
    ///
    /// - Parameters:
    ///   - socket: The _Unix file descriptor_ representing the bound stream socket.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func withBoundSocket<Output>(_ socket: NIOCore.NIOBSDSocket.Handle, channelInitializer: @escaping @Sendable (NIOCore.Channel) -> NIOCore.EventLoopFuture<Output>) async throws -> Output where Output : Sendable

    /// Bind the `DatagramChannel` to `host` and `port`.
    ///
    /// - Parameters:
    ///   - host: The host to bind on.
    ///   - port: The port to bind on.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func bind<Output>(host: String, port: Int, channelInitializer: @escaping @Sendable (NIOCore.Channel) -> NIOCore.EventLoopFuture<Output>) async throws -> Output where Output : Sendable

    /// Bind the `DatagramChannel` to the `address`.
    ///
    /// - Parameters:
    ///   - address: The `SocketAddress` to bind on.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func bind<Output>(to address: NIOCore.SocketAddress, channelInitializer: @escaping @Sendable (NIOCore.Channel) -> NIOCore.EventLoopFuture<Output>) async throws -> Output where Output : Sendable

    /// Bind the `DatagramChannel` to the `unixDomainSocketPath`.
    ///
    /// - Parameters:
    ///   - unixDomainSocketPath: The path of the UNIX Domain Socket to bind on. The`unixDomainSocketPath` must not exist,
    ///     unless `cleanupExistingSocketFile`is set to `true`.
    ///   - cleanupExistingSocketFile: Whether to cleanup an existing socket file at `unixDomainSocketPath`.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func bind<Output>(unixDomainSocketPath: String, cleanupExistingSocketFile: Bool = false, channelInitializer: @escaping @Sendable (NIOCore.Channel) -> NIOCore.EventLoopFuture<Output>) async throws -> Output where Output : Sendable

    /// Connect the `DatagramChannel` to `host` and `port`.
    ///
    /// - Parameters:
    ///   - host: The host to connect to.
    ///   - port: The port to connect to.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func connect<Output>(host: String, port: Int, channelInitializer: @escaping @Sendable (NIOCore.Channel) -> NIOCore.EventLoopFuture<Output>) async throws -> Output where Output : Sendable

    /// Connect the `DatagramChannel` to the `address`.
    ///
    /// - Parameters:
    ///   - address: The `SocketAddress` to connect to.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func connect<Output>(to address: NIOCore.SocketAddress, channelInitializer: @escaping @Sendable (NIOCore.Channel) -> NIOCore.EventLoopFuture<Output>) async throws -> Output where Output : Sendable

    /// Connect the `DatagramChannel` to the `unixDomainSocketPath`.
    ///
    /// - Parameters:
    ///   - unixDomainSocketPath: The path of the UNIX Domain Socket to connect to. `path` must not exist, it will be created by the system.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func connect<Output>(unixDomainSocketPath: String, channelInitializer: @escaping @Sendable (NIOCore.Channel) -> NIOCore.EventLoopFuture<Output>) async throws -> Output where Output : Sendable
}

extension NIOPipeBootstrap {

    /// Create the `PipeChannel` with the provided file descriptor which is used for both input & output.
    ///
    /// This method is useful for specialilsed use-cases where you want to use `NIOPipeBootstrap` for say a serial line.
    ///
    /// - Note: If this method returns a succeeded future, SwiftNIO will close `inputOutput` when the `Channel`
    ///         becomes inactive. You _must not_ do any further operations with `inputOutput`, including `close`.
    ///         If this method returns a failed future, you still own the file descriptor and are responsible for
    ///         closing it.
    ///
    /// - Parameters:
    ///   - inputOutput: The _Unix file descriptor_ for the input & output.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func takingOwnershipOfDescriptor<Output>(inputOutput: CInt, channelInitializer: @escaping @Sendable (NIOCore.Channel) -> NIOCore.EventLoopFuture<Output>) async throws -> Output where Output : Sendable

    /// Create the `PipeChannel` with the provided input and output file descriptors.
    ///
    /// The input and output file descriptors must be distinct. If you have a single file descriptor, consider using
    /// `ClientBootstrap.withConnectedSocket(descriptor:)` if it's a socket or
    /// `NIOPipeBootstrap.takingOwnershipOfDescriptor` if it is not a socket.
    ///
    /// - Note: If this method returns a succeeded future, SwiftNIO will close `input` and `output`
    ///         when the `Channel` becomes inactive. You _must not_ do any further operations `input` or
    ///         `output`, including `close`.
    ///         If this method returns a failed future, you still own the file descriptors and are responsible for
    ///         closing them.
    ///
    /// - Parameters:
    ///   - input: The _Unix file descriptor_ for the input (ie. the read side).
    ///   - output: The _Unix file descriptor_ for the output (ie. the write side).
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func takingOwnershipOfDescriptors<Output>(input: CInt, output: CInt, channelInitializer: @escaping @Sendable (NIOCore.Channel) -> NIOCore.EventLoopFuture<Output>) async throws -> Output where Output : Sendable
}

extension NIORawSocketBootstrap {

    /// Bind the `Channel` to `host`.
    /// All packets or errors matching the `ipProtocol` specified are passed to the resulting `Channel`.
    ///
    /// - Parameters:
    ///   - host: The host to bind on.
    ///   - ipProtocol: The IP protocol used in the IP protocol/nextHeader field.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `bind`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func bind<Output>(host: String, ipProtocol: NIOCore.NIOIPProtocol, channelInitializer: @escaping @Sendable (NIOCore.Channel) -> NIOCore.EventLoopFuture<Output>) async throws -> Output where Output : Sendable

    /// Connect the `Channel` to `host`.
    ///
    /// - Parameters:
    ///   - host: The host to connect to.
    ///   - ipProtocol: The IP protocol used in the IP protocol/nextHeader field.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func connect<Output>(host: String, ipProtocol: NIOCore.NIOIPProtocol, channelInitializer: @escaping @Sendable (NIOCore.Channel) -> NIOCore.EventLoopFuture<Output>) async throws -> Output where Output : Sendable
}
```

### HTTPUpgrade

```swift
/// Configuration for an upgradable HTTP pipeline.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
public struct NIOUpgradableHTTPClientPipelineConfiguration<UpgradeResult> where UpgradeResult : Sendable {

    /// The strategy to use when dealing with leftover bytes after removing the ``HTTPDecoder`` from the pipeline.
    public var leftOverBytesStrategy: NIOHTTP1.RemoveAfterUpgradeStrategy

    /// Whether to validate outbound response headers to confirm that they are
    /// spec compliant. Defaults to `true`.
    public var enableOutboundHeaderValidation: Bool

    /// The configuration for the ``HTTPRequestEncoder``.
    public var encoderConfiguration: NIOHTTP1.HTTPRequestEncoder.Configuration

    /// The configuration for the ``NIOTypedHTTPClientUpgradeHandler``.
    public var upgradeConfiguration: NIOHTTP1.NIOTypedHTTPClientUpgradeConfiguration<UpgradeResult>

    /// Initializes a new ``NIOUpgradableHTTPClientPipelineConfiguration`` with default values.
    ///
    /// The current defaults provide the following features:
    /// 1. Outbound header fields validation to protect against response splitting attacks.
    public init(upgradeConfiguration: NIOHTTP1.NIOTypedHTTPClientUpgradeConfiguration<UpgradeResult>)
}

/// Configuration for an upgradable HTTP pipeline.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
public struct NIOUpgradableHTTPServerPipelineConfiguration<UpgradeResult> where UpgradeResult : Sendable {

    /// Whether to provide assistance handling HTTP clients that pipeline
    /// their requests. Defaults to `true`. If `false`, users will need to handle clients that pipeline themselves.
    public var enablePipelining: Bool

    /// Whether to provide assistance handling protocol errors (e.g. failure to parse the HTTP
    /// request) by sending 400 errors. Defaults to `true`.
    public var enableErrorHandling: Bool

    /// Whether to validate outbound response headers to confirm that they are
    /// spec compliant. Defaults to `true`.
    public var enableResponseHeaderValidation: Bool

    /// The configuration for the ``HTTPResponseEncoder``.
    public var encoderConfiguration: NIOHTTP1.HTTPResponseEncoder.Configuration

    /// The configuration for the ``NIOTypedHTTPServerUpgradeHandler``.
    public var upgradeConfiguration: NIOHTTP1.NIOTypedHTTPServerUpgradeConfiguration<UpgradeResult>

    /// Initializes a new ``NIOUpgradableHTTPServerPipelineConfiguration`` with default values.
    ///
    /// The current defaults provide the following features:
    /// 1. Assistance handling clients that pipeline HTTP requests.
    /// 2. Assistance handling protocol errors.
    /// 3. Outbound header fields validation to protect against response splitting attacks.
    public init(upgradeConfiguration: NIOHTTP1.NIOTypedHTTPServerUpgradeConfiguration<UpgradeResult>)
}

extension ChannelPipeline {

    /// Configure a `ChannelPipeline` for use as an HTTP server.
    ///
    /// - Parameters:
    ///   - configuration: The HTTP pipeline's configuration.
    /// - Returns: An `EventLoopFuture` that will fire when the pipeline is configured. The future contains an `EventLoopFuture`
    /// that is fired once the pipeline has been upgraded or not and contains the `UpgradeResult`.
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    public func configureUpgradableHTTPServerPipeline<UpgradeResult>(configuration: NIOHTTP1.NIOUpgradableHTTPServerPipelineConfiguration<UpgradeResult>) -> NIOCore.EventLoopFuture<NIOCore.EventLoopFuture<UpgradeResult>> where UpgradeResult : Sendable
}

extension ChannelPipeline.SynchronousOperations {

    /// Configure a `ChannelPipeline` for use as an HTTP server.
    ///
    /// - Parameters:
    ///   - configuration: The HTTP pipeline's configuration.
    /// - Returns: An `EventLoopFuture` that is fired once the pipeline has been upgraded or not and contains the `UpgradeResult`.
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    public func configureUpgradableHTTPServerPipeline<UpgradeResult>(configuration: NIOHTTP1.NIOUpgradableHTTPServerPipelineConfiguration<UpgradeResult>) throws -> NIOCore.EventLoopFuture<UpgradeResult> where UpgradeResult : Sendable
}

extension ChannelPipeline {

    /// Configure a `ChannelPipeline` for use as an HTTP client.
    ///
    /// - Parameters:
    ///   - configuration: The HTTP pipeline's configuration.
    /// - Returns: An `EventLoopFuture` that will fire when the pipeline is configured. The future contains an `EventLoopFuture`
    /// that is fired once the pipeline has been upgraded or not and contains the `UpgradeResult`.
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    public func configureUpgradableHTTPClientPipeline<UpgradeResult>(configuration: NIOHTTP1.NIOUpgradableHTTPClientPipelineConfiguration<UpgradeResult>) -> NIOCore.EventLoopFuture<NIOCore.EventLoopFuture<UpgradeResult>> where UpgradeResult : Sendable
}

extension ChannelPipeline.SynchronousOperations {

    /// Configure a `ChannelPipeline` for use as an HTTP client.
    ///
    /// - Parameters:
    ///   - configuration: The HTTP pipeline's configuration.
    /// - Returns: An `EventLoopFuture` that is fired once the pipeline has been upgraded or not and contains the `UpgradeResult`.
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    public func configureUpgradableHTTPClientPipeline<UpgradeResult>(configuration: NIOHTTP1.NIOUpgradableHTTPClientPipelineConfiguration<UpgradeResult>) throws -> NIOCore.EventLoopFuture<UpgradeResult> where UpgradeResult : Sendable
}

/// An object that implements `NIOTypedHTTPClientProtocolUpgrader` knows how to handle HTTP upgrade to
/// a protocol on a client-side channel.
/// It has the option of denying this upgrade based upon the server response.
public protocol NIOTypedHTTPClientProtocolUpgrader<UpgradeResult> {

    associatedtype UpgradeResult : Sendable

    /// The protocol this upgrader knows how to support.
    var supportedProtocol: String { get }

    /// All the header fields the protocol requires in the request to successfully upgrade.
    /// These header fields will be added to the outbound request's "Connection" header field.
    /// It is the responsibility of the custom headers call to actually add these required headers.
    var requiredUpgradeHeaders: [String] { get }

    /// Additional headers to be added to the request, beyond the "Upgrade" and "Connection" headers.
    func addCustom(upgradeRequestHeaders: inout NIOHTTP1.HTTPHeaders)

    /// Gives the receiving upgrader the chance to deny the upgrade based on the upgrade HTTP response.
    func shouldAllowUpgrade(upgradeResponse: NIOHTTP1.HTTPResponseHead) -> Bool

    /// Called when the upgrade response has been flushed. At this time it is safe to mutate the channel
    /// pipeline to add whatever channel handlers are required.
    /// Until the returned `EventLoopFuture` succeeds, all received data will be buffered.
    func upgrade(channel: NIOCore.Channel, upgradeResponse: NIOHTTP1.HTTPResponseHead) -> NIOCore.EventLoopFuture<Self.UpgradeResult>
}

/// The upgrade configuration for the ``NIOTypedHTTPClientUpgradeHandler``.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
public struct NIOTypedHTTPClientUpgradeConfiguration<UpgradeResult> where UpgradeResult : Sendable {

    /// The initial request head that is sent out once the channel becomes active.
    public var upgradeRequestHead: NIOHTTP1.HTTPRequestHead

    /// The array of potential upgraders.
    public var upgraders: [NIOHTTP1.NIOTypedHTTPClientProtocolUpgrader<UpgradeResult>]

    /// A closure that is run once it is determined that no protocol upgrade is happening. This can be used
    /// to configure handlers that expect HTTP.
    public var notUpgradingCompletionHandler: @Sendable (NIOCore.Channel) -> NIOCore.EventLoopFuture<UpgradeResult>

    public init(upgradeRequestHead: NIOHTTP1.HTTPRequestHead, upgraders: [NIOHTTP1.NIOTypedHTTPClientProtocolUpgrader<UpgradeResult>], notUpgradingCompletionHandler: @escaping @Sendable (NIOCore.Channel) -> NIOCore.EventLoopFuture<UpgradeResult>)
}

/// A client-side channel handler that sends a HTTP upgrade handshake request to perform a HTTP-upgrade.
/// This handler will add all appropriate headers to perform an upgrade to
/// the a protocol. It may add headers for a set of protocols in preference order.
/// If the upgrade fails (i.e. response is not 101 Switching Protocols), this handler simply
/// removes itself from the pipeline. If the upgrade is successful, it upgrades the pipeline to the new protocol.
///
/// The request sends an order of preference to request which protocol it would like to use for the upgrade.
/// It will only upgrade to the protocol that is returned first in the list and does not currently
/// have the capability to upgrade to multiple simultaneous layered protocols.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
final public class NIOTypedHTTPClientUpgradeHandler<UpgradeResult> : NIOCore.ChannelDuplexHandler, NIOCore.RemovableChannelHandler where UpgradeResult : Sendable {

    /// The type of the outbound data which is wrapped in `NIOAny`.
    public typealias OutboundIn = NIOHTTP1.HTTPClientRequestPart

    /// The type of the outbound data which will be forwarded to the next `ChannelOutboundHandler` in the `ChannelPipeline`.
    public typealias OutboundOut = NIOHTTP1.HTTPClientRequestPart

    /// The type of the inbound data which is wrapped in `NIOAny`.
    public typealias InboundIn = NIOHTTP1.HTTPClientResponsePart

    /// The type of the inbound data which will be forwarded to the next `ChannelInboundHandler` in the `ChannelPipeline`.
    public typealias InboundOut = NIOHTTP1.HTTPClientResponsePart

    /// The upgrade future which will be completed once protocol upgrading has been done.
    public var upgradeResultFuture: NIOCore.EventLoopFuture<UpgradeResult> { get }

    /// Create a ``NIOTypedHTTPClientUpgradeHandler``.
    ///
    /// - Parameters:
    ///  - httpHandlers: All `RemovableChannelHandler` objects which will be removed from the pipeline
    ///     once the upgrade response is sent. This is used to ensure that the pipeline will be in a clean state
    ///     after the upgrade. It should include any handlers that are directly related to handling HTTP.
    ///     At the very least this should include the `HTTPEncoder` and `HTTPDecoder`, but should also include
    ///     any other handler that cannot tolerate receiving non-HTTP data.
    ///  - upgradeConfiguration: The upgrade configuration.
    public init(httpHandlers: [NIOCore.RemovableChannelHandler], upgradeConfiguration: NIOHTTP1.NIOTypedHTTPClientUpgradeConfiguration<UpgradeResult>)

    /// Called when this `ChannelHandler` is added to the `ChannelPipeline`.
    ///
    /// - Parameters:
    ///   - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    public func handlerAdded(context: NIOCore.ChannelHandlerContext)

    /// Called when this `ChannelHandler` is removed from the `ChannelPipeline`.
    ///
    /// - Parameters:
    ///   - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    public func handlerRemoved(context: NIOCore.ChannelHandlerContext)

    /// Called when the `Channel` has become active, and is able to send and receive data.
    ///
    /// This should call `context.fireChannelActive` to forward the operation to the next `_ChannelInboundHandler` in the `ChannelPipeline` if you want to allow the next handler to also handle the event.
    ///
    /// - Parameters:
    ///   - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    public func channelActive(context: NIOCore.ChannelHandlerContext)

    /// Called to request a write operation. The write operation will write the messages through the
    /// `ChannelPipeline`. Those are then ready to be flushed to the actual `Channel` when
    /// `Channel.flush` or `ChannelHandlerContext.flush` is called.
    ///
    /// This should call `context.write` to forward the operation to the next `_ChannelOutboundHandler` in the `ChannelPipeline` or
    /// complete the `EventLoopPromise` to let the caller know that the operation completed.
    ///
    /// - Parameters:
    ///   - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    ///   - data: The data to write through the `Channel`, wrapped in a `NIOAny`.
    ///   - promise: The `EventLoopPromise` which should be notified once the operation completes, or nil if no notification should take place.
    public func write(context: NIOCore.ChannelHandlerContext, data: NIOCore.NIOAny, promise: NIOCore.EventLoopPromise<Void>?)

    /// Called when some data has been read from the remote peer.
    ///
    /// This should call `context.fireChannelRead` to forward the operation to the next `_ChannelInboundHandler` in the `ChannelPipeline` if you want to allow the next handler to also handle the event.
    ///
    /// - Parameters:
    ///   - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    ///   - data: The data read from the remote peer, wrapped in a `NIOAny`.
    public func channelRead(context: NIOCore.ChannelHandlerContext, data: NIOCore.NIOAny)
}

/// An object that implements `NIOTypedHTTPServerProtocolUpgrader` knows how to handle HTTP upgrade to
/// a protocol on a server-side channel.
public protocol NIOTypedHTTPServerProtocolUpgrader<UpgradeResult> {

    associatedtype UpgradeResult : Sendable

    /// The protocol this upgrader knows how to support.
    var supportedProtocol: String { get }

    /// All the header fields the protocol needs in the request to successfully upgrade. These header fields
    /// will be provided to the handler when it is asked to handle the upgrade. They will also be validated
    /// against the inbound request's `Connection` header field.
    var requiredUpgradeHeaders: [String] { get }

    /// Builds the upgrade response headers. Should return any headers that need to be supplied to the client
    /// in the 101 Switching Protocols response. If upgrade cannot proceed for any reason, this function should
    /// return a failed future.
    func buildUpgradeResponse(channel: NIOCore.Channel, upgradeRequest: NIOHTTP1.HTTPRequestHead, initialResponseHeaders: NIOHTTP1.HTTPHeaders) -> NIOCore.EventLoopFuture<NIOHTTP1.HTTPHeaders>

    /// Called when the upgrade response has been flushed. At this time it is safe to mutate the channel pipeline
    /// to add whatever channel handlers are required. Until the returned `EventLoopFuture` succeeds, all received
    /// data will be buffered.
    func upgrade(channel: NIOCore.Channel, upgradeRequest: NIOHTTP1.HTTPRequestHead) -> NIOCore.EventLoopFuture<Self.UpgradeResult>
}

/// The upgrade configuration for the ``NIOTypedHTTPServerUpgradeHandler``.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
public struct NIOTypedHTTPServerUpgradeConfiguration<UpgradeResult> where UpgradeResult : Sendable {

    /// The array of potential upgraders.
    public var upgraders: [NIOHTTP1.NIOTypedHTTPServerProtocolUpgrader<UpgradeResult>]

    /// A closure that is run once it is determined that no protocol upgrade is happening. This can be used
    /// to configure handlers that expect HTTP.
    public var notUpgradingCompletionHandler: @Sendable (NIOCore.Channel) -> NIOCore.EventLoopFuture<UpgradeResult>

    public init(upgraders: [NIOHTTP1.NIOTypedHTTPServerProtocolUpgrader<UpgradeResult>], notUpgradingCompletionHandler: @escaping @Sendable (NIOCore.Channel) -> NIOCore.EventLoopFuture<UpgradeResult>)
}

/// A server-side channel handler that receives HTTP requests and optionally performs an HTTP-upgrade.
///
/// Removes itself from the channel pipeline after the first inbound request on the connection, regardless of
/// whether the upgrade succeeded or not.
///
/// This handler behaves a bit differently from its Netty counterpart because it does not allow upgrade
/// on any request but the first on a connection. This is primarily to handle clients that pipeline: it's
/// sufficiently difficult to ensure that the upgrade happens at a safe time while dealing with pipelined
/// requests that we choose to punt on it entirely and not allow it. As it happens this is mostly fine:
/// the odds of someone needing to upgrade midway through the lifetime of a connection are very low.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
final public class NIOTypedHTTPServerUpgradeHandler<UpgradeResult> : NIOCore.ChannelInboundHandler, NIOCore.RemovableChannelHandler where UpgradeResult : Sendable {

    /// The type of the inbound data which is wrapped in `NIOAny`.
    public typealias InboundIn = NIOHTTP1.HTTPServerRequestPart

    /// The type of the inbound data which will be forwarded to the next `ChannelInboundHandler` in the `ChannelPipeline`.
    public typealias InboundOut = NIOHTTP1.HTTPServerRequestPart

    /// The type of the outbound data which will be forwarded to the next `ChannelOutboundHandler` in the `ChannelPipeline`.
    public typealias OutboundOut = NIOHTTP1.HTTPServerResponsePart

    /// The upgrade future which will be completed once protocol upgrading has been done.
    public var upgradeResultFuture: NIOCore.EventLoopFuture<UpgradeResult> { get }

    /// Create a ``NIOTypedHTTPServerUpgradeHandler``.
    /// 
    /// - Parameters:
    ///   - httpEncoder: The ``HTTPResponseEncoder`` encoding responses from this handler and which will
    ///     be removed from the pipeline once the upgrade response is sent. This is used to ensure
    ///     that the pipeline will be in a clean state after upgrade.
    ///  - extraHTTPHandlers: Any other handlers that are directly related to handling HTTP. At the very least
    ///     this should include the `HTTPDecoder`, but should also include any other handler that cannot tolerate
    ///     receiving non-HTTP data.
    ///  - upgradeConfiguration: The upgrade configuration.
    public init(httpEncoder: NIOHTTP1.HTTPResponseEncoder, extraHTTPHandlers: [NIOCore.RemovableChannelHandler], upgradeConfiguration: NIOHTTP1.NIOTypedHTTPServerUpgradeConfiguration<UpgradeResult>)

    /// Called when this `ChannelHandler` is added to the `ChannelPipeline`.
    ///
    /// - Parameters:
    ///   - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    public func handlerAdded(context: NIOCore.ChannelHandlerContext)

    /// Called when this `ChannelHandler` is removed from the `ChannelPipeline`.
    ///
    /// - Parameters:
    ///   - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    public func handlerRemoved(context: NIOCore.ChannelHandlerContext)

    /// Called when some data has been read from the remote peer.
    ///
    /// This should call `context.fireChannelRead` to forward the operation to the next `_ChannelInboundHandler` in the `ChannelPipeline` if you want to allow the next handler to also handle the event.
    ///
    /// - Parameters:
    ///   - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    ///   - data: The data read from the remote peer, wrapped in a `NIOAny`.
    public func channelRead(context: NIOCore.ChannelHandlerContext, data: NIOCore.NIOAny)
}
```

### Websocket

```swift
/// A `NIOTypedHTTPClientProtocolUpgrader` that knows how to do the WebSocket upgrade dance.
///
/// This upgrader assumes that the `HTTPClientUpgradeHandler` will create and send the upgrade request.
/// This upgrader also assumes that the `HTTPClientUpgradeHandler` will appropriately mutate the
/// pipeline to remove the HTTP `ChannelHandler`s.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
final public class NIOTypedWebSocketClientUpgrader<UpgradeResult> : NIOHTTP1.NIOTypedHTTPClientProtocolUpgrader where UpgradeResult : Sendable {

    /// RFC 6455 specs this as the required entry in the Upgrade header.
    public let supportedProtocol: String

    /// None of the websocket headers are actually defined as 'required'.
    public let requiredUpgradeHeaders: [String]

    /// - Parameters:
    ///   - requestKey: Sent to the server in the `Sec-WebSocket-Key` HTTP header. Default is random request key.
    ///   - maxFrameSize: Largest incoming `WebSocketFrame` size in bytes. Default is 16,384 bytes.
    ///   - enableAutomaticErrorHandling: If true, adds `WebSocketProtocolErrorHandler` to the channel pipeline to catch and respond to WebSocket protocol errors. Default is true.
    ///   - upgradePipelineHandler: Called once the upgrade was successful.
    public init(requestKey: String = NIOWebSocketClientUpgrader.randomRequestKey(), maxFrameSize: Int = 1 << 14, enableAutomaticErrorHandling: Bool = true, upgradePipelineHandler: @escaping @Sendable (NIOCore.Channel, NIOHTTP1.HTTPResponseHead) -> NIOCore.EventLoopFuture<UpgradeResult>)

    /// Additional headers to be added to the request, beyond the "Upgrade" and "Connection" headers.
    public func addCustom(upgradeRequestHeaders: inout NIOHTTP1.HTTPHeaders)

    /// Gives the receiving upgrader the chance to deny the upgrade based on the upgrade HTTP response.
    public func shouldAllowUpgrade(upgradeResponse: NIOHTTP1.HTTPResponseHead) -> Bool

    /// Called when the upgrade response has been flushed. At this time it is safe to mutate the channel
    /// pipeline to add whatever channel handlers are required.
    /// Until the returned `EventLoopFuture` succeeds, all received data will be buffered.
    public func upgrade(channel: NIOCore.Channel, upgradeResponse: NIOHTTP1.HTTPResponseHead) -> NIOCore.EventLoopFuture<UpgradeResult>
}

/// A `NIOTypedHTTPServerProtocolUpgrader` that knows how to do the WebSocket upgrade dance.
///
/// Users may frequently want to offer multiple websocket endpoints on the same port. For this
/// reason, this `WebServerSocketUpgrader` only knows how to do the required parts of the upgrade and to
/// complete the handshake. Users are expected to provide a callback that examines the HTTP headers
/// (including the path) and determines whether this is a websocket upgrade request that is acceptable
/// to them.
///
/// This upgrader assumes that the `HTTPServerUpgradeHandler` will appropriately mutate the pipeline to
/// remove the HTTP `ChannelHandler`s.
final public class NIOTypedWebSocketServerUpgrader<UpgradeResult> : NIOHTTP1.NIOTypedHTTPServerProtocolUpgrader, Sendable where UpgradeResult : Sendable {

    /// RFC 6455 specs this as the required entry in the Upgrade header.
    public let supportedProtocol: String

    /// We deliberately do not actually set any required headers here, because the websocket
    /// spec annoyingly does not actually force the client to send these in the Upgrade header,
    /// which NIO requires. We check for these manually.
    public let requiredUpgradeHeaders: [String]

    /// Create a new ``NIOTypedWebSocketServerUpgrader``.
    ///
    /// - Parameters:
    ///   - maxFrameSize: The maximum frame size the decoder is willing to tolerate from the
    ///         remote peer. WebSockets in principle allows frame sizes up to `2**64` bytes, but
    ///         this is an objectively unreasonable maximum value (on AMD64 systems it is not
    ///         possible to even. Users may set this to any value up to `UInt32.max`.
    ///   - automaticErrorHandling: Whether the pipeline should automatically handle protocol
    ///         errors by sending error responses and closing the connection. Defaults to `true`,
    ///         may be set to `false` if the user wishes to handle their own errors.
    ///   - shouldUpgrade: A callback that determines whether the websocket request should be
    ///         upgraded. This callback is responsible for creating a `HTTPHeaders` object with
    ///         any headers that it needs on the response *except for* the `Upgrade`, `Connection`,
    ///         and `Sec-WebSocket-Accept` headers, which this upgrader will handle. Should return
    ///         an `EventLoopFuture` containing `nil` if the upgrade should be refused.
    ///   - enableAutomaticErrorHandling: A function that will be called once the upgrade response is
    ///         flushed, and that is expected to mutate the `Channel` appropriately to handle the
    ///         websocket protocol. This only needs to add the user handlers: the
    ///         `WebSocketFrameEncoder` and `WebSocketFrameDecoder` will have been added to the
    ///         pipeline automatically.
    public init(maxFrameSize: Int = 1 << 14, enableAutomaticErrorHandling: Bool = true, shouldUpgrade: @escaping @Sendable (NIOCore.Channel, NIOHTTP1.HTTPRequestHead) -> NIOCore.EventLoopFuture<NIOHTTP1.HTTPHeaders?>, upgradePipelineHandler: @escaping @Sendable (NIOCore.Channel, NIOHTTP1.HTTPRequestHead) -> NIOCore.EventLoopFuture<UpgradeResult>)

    /// Builds the upgrade response headers. Should return any headers that need to be supplied to the client
    /// in the 101 Switching Protocols response. If upgrade cannot proceed for any reason, this function should
    /// return a failed future.
    public func buildUpgradeResponse(channel: NIOCore.Channel, upgradeRequest: NIOHTTP1.HTTPRequestHead, initialResponseHeaders: NIOHTTP1.HTTPHeaders) -> NIOCore.EventLoopFuture<NIOHTTP1.HTTPHeaders>

    /// Called when the upgrade response has been flushed. At this time it is safe to mutate the channel pipeline
    /// to add whatever channel handlers are required. Until the returned `EventLoopFuture` succeeds, all received
    /// data will be buffered.
    public func upgrade(channel: NIOCore.Channel, upgradeRequest: NIOHTTP1.HTTPRequestHead) -> NIOCore.EventLoopFuture<UpgradeResult>
}
```

### ALPN

```swift
/// A helper ``ChannelInboundHandler`` that makes it easy to swap channel pipelines
/// based on the result of an ALPN negotiation.
///
/// The standard pattern used by applications that want to use ALPN is to select
/// an application protocol based on the result, optionally falling back to some
/// default protocol. To do this in SwiftNIO requires that the channel pipeline be
/// reconfigured based on the result of the ALPN negotiation. This channel handler
/// encapsulates that logic in a generic form that doesn't depend on the specific
/// TLS implementation in use by using ``TLSUserEvent``
///
/// The user of this channel handler provides a single closure that is called with
/// an ``ALPNResult`` when the ALPN negotiation is complete. Based on that result
/// the user is free to reconfigure the ``ChannelPipeline`` as required, and should
/// return an ``EventLoopFuture`` that will complete when the pipeline is reconfigured.
///
/// Until the ``EventLoopFuture`` completes, this channel handler will buffer inbound
/// data. When the ``EventLoopFuture`` completes, the buffered data will be replayed
/// down the channel. Then, finally, this channel handler will automatically remove
/// itself from the channel pipeline, leaving the pipeline in its final
/// configuration.
///
/// Importantly, this is a typed variant of the ``ApplicationProtocolNegotiationHandler`` and allows the user to
/// specify a type that must be returned from the supplied closure. The result will then be used to succeed the ``NIOTypedApplicationProtocolNegotiationHandler/protocolNegotiationResult``
/// promise. This allows us to construct pipelines that include protocol negotiation handlers and be able to bridge them into ``NIOAsyncChannel``
/// based bootstraps.
final public class NIOTypedApplicationProtocolNegotiationHandler<NegotiationResult> : NIOCore.ChannelInboundHandler, NIOCore.RemovableChannelHandler {

    /// The type of the inbound data which is wrapped in `NIOAny`.
    public typealias InboundIn = Any

    /// The type of the inbound data which will be forwarded to the next `ChannelInboundHandler` in the `ChannelPipeline`.
    public typealias InboundOut = Any

    public var protocolNegotiationResult: NIOCore.EventLoopFuture<NegotiationResult> { get }

    /// Create an `ApplicationProtocolNegotiationHandler` with the given completion
    /// callback.
    ///
    /// - Parameter alpnCompleteHandler: The closure that will fire when ALPN
    ///   negotiation has completed.
    public init(alpnCompleteHandler: @escaping (NIOTLS.ALPNResult, NIOCore.Channel) -> NIOCore.EventLoopFuture<NegotiationResult>)

    /// Create an `ApplicationProtocolNegotiationHandler` with the given completion
    /// callback.
    ///
    /// - Parameter alpnCompleteHandler: The closure that will fire when ALPN
    ///   negotiation has completed.
    public convenience init(alpnCompleteHandler: @escaping (NIOTLS.ALPNResult) -> NIOCore.EventLoopFutureNegotiationResult>)

    /// Called when this `ChannelHandler` is added to the `ChannelPipeline`.
    ///
    /// - Parameters:
    ///   - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    public func handlerAdded(context: NIOCore.ChannelHandlerContext)

    /// Called when this `ChannelHandler` is removed from the `ChannelPipeline`.
    ///
    /// - Parameters:
    ///   - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    public func handlerRemoved(context: NIOCore.ChannelHandlerContext)

    /// Called when a user inbound event has been triggered.
    ///
    /// This should call `context.fireUserInboundEventTriggered` to forward the operation to the next `_ChannelInboundHandler` in the `ChannelPipeline` if you want to allow the next handler to also handle the event.
    ///
    /// - Parameters:
    ///   - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    ///   - event: The event.
    public func userInboundEventTriggered(context: NIOCore.ChannelHandlerContext, event: Any)

    /// Called when some data has been read from the remote peer.
    ///
    /// This should call `context.fireChannelRead` to forward the operation to the next `_ChannelInboundHandler` in the `ChannelPipeline` if you want to allow the next handler to also handle the event.
    ///
    /// - Parameters:
    ///   - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    ///   - data: The data read from the remote peer, wrapped in a `NIOAny`.
    public func channelRead(context: NIOCore.ChannelHandlerContext, data: NIOCore.NIOAny)

    /// Called when the `Channel` has become inactive and is no longer able to send and receive data.
    ///
    /// This should call `context.fireChannelInactive` to forward the operation to the next `_ChannelInboundHandler` in the `ChannelPipeline` if you want to allow the next handler to also handle the event.
    ///
    /// - Parameters:
    ///   - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    public func channelInactive(context: NIOCore.ChannelHandlerContext)
}
```

### HTTP/2.0

```swift
extension NIOHTTP2Handler {
    /// A variant of `NIOHTTP2Handler.StreamMultiplexer` which creates a child channel for each HTTP/2 stream and
    /// provides access to inbound HTTP/2 streams.
    ///
    /// In general in NIO applications it is helpful to consider each HTTP/2 stream as an
    /// independent stream of HTTP/2 frames. This multiplexer achieves this by creating a
    /// number of in-memory `HTTP2StreamChannel` objects, one for each stream. These operate
    /// on ``HTTP2Frame/FramePayload`` objects as their base communication
    /// atom, as opposed to the regular NIO `SelectableChannel` objects which use `ByteBuffer`
    /// and `IOData`.
    ///
    /// Outbound stream channel objects are initialized upon creation using the supplied `streamStateInitializer` which returns a type
    /// `Output`. This type may be `HTTP2Frame` or changed to any other type.
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    public struct AsyncStreamMultiplexer<InboundStreamOutput> {
        /// Create a stream channel initialized with the provided closure
        public func createStreamChannel<Output: Sendable>(_ initializer: @escaping NIOChannelInitializerWithOutput<Output>) async throws -> Output
    }
}

/// `NIOHTTP2InboundStreamChannels` provides access to inbound stream channels as a generic `AsyncSequence`.
/// They make use of generics to allow for wrapping the stream `Channel`s, for example as `NIOAsyncChannel`s or protocol negotiation objects.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct NIOHTTP2InboundStreamChannels<Output>: AsyncSequence {
    public struct AsyncIterator: AsyncIteratorProtocol {
        public typealias Element = Output

        public mutating func next() async throws -> Output?
    }

    public typealias Element = Output

    public func makeAsyncIterator() -> AsyncIterator
}

extension Channel {
    /// Configures a `ChannelPipeline` to speak HTTP/2 and sets up mapping functions so that it may be interacted with from concurrent code.
    ///
    /// In general this is not entirely useful by itself, as HTTP/2 is a negotiated protocol. This helper does not handle negotiation.
    /// Instead, this simply adds the handler required to speak HTTP/2 after negotiation has completed, or when agreed by prior knowledge.
    /// Use this function to setup a HTTP/2 pipeline if you wish to use async sequence abstractions over inbound and outbound streams.
    /// Using this rather than implementing a similar function yourself allows that pipeline to evolve without breaking your code.
    ///
    /// - Parameters:
    ///   - mode: The mode this pipeline will operate in, server or client.
    ///   - configuration: The settings that will be used when establishing the connection and new streams.
    ///   - inboundStreamInitializer: A closure that will be called whenever the remote peer initiates a new stream.
    ///     The output of this closure is the element type of the returned multiplexer
    /// - Returns: An `EventLoopFuture` containing the `AsyncStreamMultiplexer` inserted into this pipeline, which can
    ///     be used to initiate new streams and iterate over inbound HTTP/2 stream channels.
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    public func configureAsyncHTTP2Pipeline<Output: Sendable>(
        mode: NIOHTTP2Handler.ParserMode,
        configuration: NIOHTTP2Handler.Configuration = .init(),
        inboundStreamInitializer: @escaping NIOChannelInitializerWithOutput<Output>
    ) -> EventLoopFuture<NIOHTTP2Handler.AsyncStreamMultiplexer<Output>>

    /// Configures a `ChannelPipeline` to speak either HTTP/1.1 or HTTP/2 according to what can be negotiated with the client.
    ///
    /// This helper takes care of configuring the server pipeline such that it negotiates whether to
    /// use HTTP/1.1 or HTTP/2.
    ///
    /// This function doesn't configure the TLS handler. Callers of this function need to add a TLS
    /// handler appropriately configured to perform protocol negotiation.
    ///
    /// - Parameters:
    ///   - http2Configuration: The settings that will be used when establishing the HTTP/2 connections and new HTTP/2 streams.
    ///   - http1ConnectionInitializer: An optional callback that will be invoked only when the negotiated protocol
    ///     is HTTP/1.1 to configure the connection channel.
    ///   - http2ConnectionInitializer: An optional callback that will be invoked only when the negotiated protocol
    ///     is HTTP/2 to configure the connection channel.
    ///   - http2InboundStreamInitializer: A closure that will be called whenever the remote peer initiates a new stream.
    ///     The output of this closure is the element type of the returned multiplexer
    /// - Returns: An `EventLoopFuture` containing a ``NIOTypedApplicationProtocolNegotiationHandler`` that completes when the channel
    ///     is ready to negotiate. This can then be used to access the protocol negotiation result which may itself
    ///     be waited on to retrieve the result of the negotiation.
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    public func configureAsyncHTTPServerPipeline<HTTP1ConnectionOutput: Sendable, HTTP2ConnectionOutput: Sendable, HTTP2StreamOutput: Sendable>(
        http2Configuration: NIOHTTP2Handler.Configuration = .init(),
        http1ConnectionInitializer: @escaping NIOChannelInitializerWithOutput<HTTP1ConnectionOutput>,
        http2ConnectionInitializer: @escaping NIOChannelInitializerWithOutput<HTTP2ConnectionOutput>,
        http2InboundStreamInitializer: @escaping NIOChannelInitializerWithOutput<HTTP2StreamOutput>
    ) -> EventLoopFuture<EventLoopFuture<NIONegotiatedHTTPVersion<
            HTTP1ConnectionOutput,
            (HTTP2ConnectionOutput, NIOHTTP2Handler.AsyncStreamMultiplexer<HTTP2StreamOutput>)
        >>>

extension ChannelPipeline.SynchronousOperations {
    /// Configures a `ChannelPipeline` to speak HTTP/2 and sets up mapping functions so that it may be interacted with from concurrent code.
    ///
    /// This operation **must** be called on the event loop.
    ///
    /// In general this is not entirely useful by itself, as HTTP/2 is a negotiated protocol. This helper does not handle negotiation.
    /// Instead, this simply adds the handler required to speak HTTP/2 after negotiation has completed, or when agreed by prior knowledge.
    /// Use this function to setup a HTTP/2 pipeline if you wish to use async sequence abstractions over inbound and outbound streams,
    /// as it allows that pipeline to evolve without breaking your code.
    ///
    /// - Parameters:
    ///   - mode: The mode this pipeline will operate in, server or client.
    ///   - configuration: The settings that will be used when establishing the connection and new streams.
    ///   - inboundStreamInitializer: A closure that will be called whenever the remote peer initiates a new stream.
    ///     The output of this closure is the element type of the returned multiplexer
    /// - Returns: An `EventLoopFuture` containing the `AsyncStreamMultiplexer` inserted into this pipeline, which can
    /// be used to initiate new streams and iterate over inbound HTTP/2 stream channels.
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    public func configureAsyncHTTP2Pipeline<Output: Sendable>(
        mode: NIOHTTP2Handler.ParserMode,
        configuration: NIOHTTP2Handler.Configuration = .init(),
        inboundStreamInitializer: @escaping NIOChannelInitializerWithOutput<Output>
    ) throws -> NIOHTTP2Handler.AsyncStreamMultiplexer<Output>
}

/// `NIONegotiatedHTTPVersion` is a generic negotiation result holder for HTTP/1.1 and HTTP/2
public enum NIONegotiatedHTTPVersion<HTTP1Output: Sendable, HTTP2Output: Sendable> {
    case http1_1(HTTP1Output)
    case http2(HTTP2Output)
}
```
