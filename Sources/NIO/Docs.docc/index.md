# ``NIO`` <!-- SwiftNIO -->

Event-driven, non-blocking, network application framework for high performance protocol servers & clients.

## Overview

SwiftNIO is a cross-platform asynchronous event-driven network application framework for rapid development of maintainable high performance protocol servers & clients.

It's like Netty, but written for Swift.

### Repository organization

The SwiftNIO project is split across multiple repositories:

Repo | Usage
--|--
[swift-nio][repo-nio] | SwiftNIO core
[swift-nio-ssl][repo-nio-ssl] | TLS (SSL) support
[swift-nio-http2][repo-nio-http2] | HTTP/2 support
[swift-nio-extras][repo-nio-extras] | Useful additions around SwiftNIO
[swift-nio-transport-services][repo-nio-transport-services] | First-class support for macOS, iOS, tvOS, and watchOS
[swift-nio-ssh][repo-nio-ssh] | SSH support

### Modules

SwiftNIO has a number of products that provide different functionality. This package includes the following products:

- ``NIO``. This is an umbrella module exporting [NIOCore][module-core], [NIOEmbedded][module-embedded] and [NIOPosix][module-posix].
- [NIOCore][module-core]. This provides the core abstractions and types for using SwiftNIO (see ["Conceptual Overview"](#Conceptual-Overview) for more details). Most NIO extension projects that provide things like new [`EventLoop`s][el] and [`Channel`s][c] or new protocol implementations should only need to depend on [NIOCore][module-core].
- [NIOPosix][module-posix]. This provides the primary [`EventLoopGroup`][elg], [`EventLoop`][el], and [`Channel`s][c] for use on POSIX-based systems. This is our high performance core I/O layer. In general, this should only be imported by projects that plan to do some actual I/O, such as high-level protocol implementations or applications.
- [NIOEmbedded][module-embedded]. This provides [`EmbeddedChannel`][ec] and [`EmbeddedEventLoop`][eel], implementations of the [NIOCore][module-core] abstractions that provide fine-grained control over their execution. These are most often used for testing, but can also be used to drive protocol implementations in a way that is decoupled from networking altogether.
- [NIOConcurrencyHelpers][module-concurrency-helpers]. This provides a few low-level concurrency primitives that are used by NIO implementations, such as locks and atomics.
- [NIOFoundationCompat][module-foundation-compatibility]. This extends a number of NIO types for better interoperation with Foundation data types. If you are working with Foundation data types such as `Data`, you should import this.
- [NIOTLS][module-tls]. This provides a few common abstraction types for working with multiple TLS implementations. Note that this doesn't provide TLS itself: please investigate [swift-nio-ssl][repo-nio-ssl] and [swift-nio-transport-services][repo-nio-transport-services] for concrete implementations.
- [NIOHTTP1][module-http1]. This provides a low-level HTTP/1.1 protocol implementation.
- [NIOWebSocket][module-websocket]. This provides a low-level WebSocket protocol implementation.
- [NIOTestUtils][module-test-utilities]. This provides a number of helpers for testing projects that use SwiftNIO.
- [NIOFileSystem][module-filesystem]. This provides `async` APIs for interacting with the file system.

### Conceptual Overview

SwiftNIO is fundamentally a low-level tool for building high-performance networking applications in Swift. It particularly targets those use-cases where using a "thread-per-connection" model of concurrency is inefficient or untenable. This is a common limitation when building servers that use a large number of relatively low-utilization connections, such as HTTP servers.

To achieve its goals SwiftNIO extensively uses "non-blocking I/O": hence the name! Non-blocking I/O differs from the more common blocking I/O model because the application does not wait for data to be sent to or received from the network: instead, SwiftNIO asks for the kernel to notify it when I/O operations can be performed without waiting.

SwiftNIO does not aim to provide high-level solutions like, for example, web frameworks do. Instead, SwiftNIO is focused on providing the low-level building blocks for these higher-level applications. When it comes to building a web application, most users will not want to use SwiftNIO directly: instead, they'll want to use one of the many great web frameworks available in the Swift ecosystem. Those web frameworks, however, may choose to use SwiftNIO under the covers to provide their networking support.

The following sections will describe the low-level tools that SwiftNIO provides, and provide a quick overview of how to work with them. If you feel comfortable with these concepts, then you can skip right ahead to the other sections of this document.

#### Basic Architecture

The basic building blocks of SwiftNIO are the following 8 types of objects:

- [`EventLoopGroup`][elg], a protocol, provided by [NIOCore][module-core].
- [`EventLoop`][el], a protocol, provided by [NIOCore][module-core].
- [`Channel`][c], a protocol, provided by [NIOCore][module-core].
- [`ChannelHandler`][ch], a protocol, provided by [NIOCore][module-core].
- `Bootstrap`, several related structures, provided by [NIOCore][module-core].
- [`ByteBuffer`][bb], a struct, provided by [NIOCore][module-core].
- [`EventLoopFuture`][elf], a generic class, provided by [NIOCore][module-core].
- [`EventLoopPromise`][elp], a generic struct, provided by [NIOCore][module-core].

All SwiftNIO applications are ultimately constructed of these various components.

##### EventLoops and EventLoopGroups

The basic I/O primitive of SwiftNIO is the event loop. The event loop is an object that waits for events (usually I/O related events, such as "data received") to happen and then fires some kind of callback when they do. In almost all SwiftNIO applications there will be relatively few event loops: usually only one or two per CPU core the application wants to use. Generally speaking event loops run for the entire lifetime of your application, spinning in an endless loop dispatching events.

Event loops are gathered together into event loop *groups*. These groups provide a mechanism to distribute work around the event loops. For example, when listening for inbound connections the listening socket will be registered on one event loop. However, we don't want all connections that are accepted on that listening socket to be registered with the same event loop, as that would potentially overload one event loop while leaving the others empty. For that reason, the event loop group provides the ability to spread load across multiple event loops.

In SwiftNIO today there is one [`EventLoopGroup`][elg] implementation, and two [`EventLoop`][el] implementations. For production applications there is the [`MultiThreadedEventLoopGroup`][mtelg], an [`EventLoopGroup`][elg] that creates a number of threads (using the POSIX [`pthreads`][pthreads] library) and places one `SelectableEventLoop` on each one. The `SelectableEventLoop` is an event loop that uses a selector (either [`kqueue`][kqueue] or [`epoll`][epoll] depending on the target system) to manage I/O events from file descriptors and to dispatch work. These [`EventLoop`s][el] and [`EventLoopGroup`s][elg] are provided by the [NIOPosix][module-posix] module. Additionally, there is the [`EmbeddedEventLoop`][eel], which is a dummy event loop that is used primarily for testing purposes, provided by the [NIOEmbedded][module-embedded] module.

[`EventLoop`][el]s have a number of important properties. Most vitally, they are the way all work gets done in SwiftNIO applications. In order to ensure thread-safety, any work that wants to be done on almost any of the other objects in SwiftNIO must be dispatched via an [`EventLoop`][el]. [`EventLoop`][el] objects own almost all the other objects in a SwiftNIO application, and understanding their execution model is critical for building high-performance SwiftNIO applications.

##### Channels, Channel Handlers, Channel Pipelines, and Channel Contexts

While [`EventLoop`][el]s are critical to the way SwiftNIO works, most users will not interact with them substantially beyond asking them to create [`EventLoopPromise`][elp]s and to schedule work. The parts of a SwiftNIO application most users will spend the most time interacting with are [`Channel`][c]s and [`ChannelHandler`][ch]s.

Almost every file descriptor that a user interacts with in a SwiftNIO program is associated with a single [`Channel`][c]. The [`Channel`][c] owns this file descriptor, and is responsible for managing its lifetime. It is also responsible for processing inbound and outbound events on that file descriptor: whenever the event loop has an event that corresponds to a file descriptor, it will notify the [`Channel`][c] that owns that file descriptor.

[`Channel`][c]s by themselves, however, are not useful. After all, it is a rare application that doesn't want to do anything with the data it sends or receives on a socket! So the other important part of the [`Channel`][c] is the [`ChannelPipeline`][cp].

A [`ChannelPipeline`][cp] is a sequence of objects, called [`ChannelHandler`][ch]s, that process events on a [`Channel`][c]. The [`ChannelHandler`][ch]s process these events one after another, in order, mutating and transforming events as they go. This can be thought of as a data processing pipeline; hence the name [`ChannelPipeline`][cp].

All [`ChannelHandler`][ch]s are either Inbound or Outbound handlers, or both. Inbound handlers process "inbound" events: events like reading data from a socket, reading socket close, or other kinds of events initiated by remote peers. Outbound handlers process "outbound" events, such as writes, connection attempts, and local socket closes.

Each handler processes the events in order. For example, read events are passed from the front of the pipeline to the back, one handler at a time, while write events are passed from the back of the pipeline to the front. Each handler may, at any time, generate either inbound or outbound events that will be sent to the next handler in whichever direction is appropriate. This allows handlers to split up reads, coalesce writes, delay connection attempts, and generally perform arbitrary transformations of events.

In general, [`ChannelHandler`][ch]s are designed to be highly re-usable components. This means they tend to be designed to be as small as possible, performing one specific data transformation. This allows handlers to be composed together in novel and flexible ways, which helps with code reuse and encapsulation.

[`ChannelHandler`][ch]s are able to keep track of where they are in a [`ChannelPipeline`][cp] by using a [`ChannelHandlerContext`][chc]. These objects contain references to the previous and next channel handler in the pipeline, ensuring that it is always possible for a [`ChannelHandler`][ch] to emit events while it remains in a pipeline.

SwiftNIO ships with many [`ChannelHandler`][ch]s built in that provide useful functionality, such as HTTP parsing. In addition, high-performance applications will want to provide as much of their logic as possible in [`ChannelHandler`][ch]s, as it helps avoid problems with context switching.

Additionally, SwiftNIO ships with a few [`Channel`][c] implementations. In particular, it ships with `ServerSocketChannel`, a [`Channel`][c] for sockets that accept inbound connections; `SocketChannel`, a [`Channel`][c] for TCP connections; and `DatagramChannel`, a [`Channel`][c] for UDP sockets. All of these are provided by the [NIOPosix][module-posix] module. It also provides[`EmbeddedChannel`][ec], a [`Channel`][c] primarily used for testing, provided by the [NIOEmbedded][module-embedded] module.

###### A Note on Blocking

One of the important notes about [`ChannelPipeline`][cp]s is that they are thread-safe. This is very important for writing SwiftNIO applications, as it allows you to write much simpler [`ChannelHandler`][ch]s in the knowledge that they will not require synchronization.

However, this is achieved by dispatching all code on the [`ChannelPipeline`][cp] on the same thread as the [`EventLoop`][el]. This means that, as a general rule, [`ChannelHandler`][ch]s **must not** call blocking code without dispatching it to a background thread. If a [`ChannelHandler`][ch] blocks for any reason, all [`Channel`][c]s attached to the parent [`EventLoop`][el] will be unable to progress until the blocking call completes.

This is a common concern while writing SwiftNIO applications. If it is useful to write code in a blocking style, it is highly recommended that you dispatch work to a different thread when you're done with it in your pipeline.

##### Bootstrap

While it is possible to configure and register [`Channel`][c]s with [`EventLoop`][el]s directly, it is generally more useful to have a higher-level abstraction to handle this work.

For this reason, SwiftNIO ships a number of `Bootstrap` objects whose purpose is to streamline the creation of channels. Some `Bootstrap` objects also provide other functionality, such as support for Happy Eyeballs for making TCP connection attempts.

Currently SwiftNIO ships with three `Bootstrap` objects in the [NIOPosix][module-posix] module: [`ServerBootstrap`][sb], for bootstrapping listening channels; [`ClientBootstrap`][cb], for bootstrapping client TCP channels; and [`DatagramBootstrap`][db] for bootstrapping UDP channels.

##### ByteBuffer

The majority of the work in a SwiftNIO application involves shuffling buffers of bytes around. At the very least, data is sent and received to and from the network in the form of buffers of bytes. For this reason it's very important to have a high-performance data structure that is optimized for the kind of work SwiftNIO applications perform.

For this reason, SwiftNIO provides [`ByteBuffer`][bb], a fast copy-on-write byte buffer that forms a key building block of most SwiftNIO applications. This type is provided by the [NIOCore][module-core] module.

[`ByteBuffer`][bb] provides a number of useful features, and in addition provides a number of hooks to use it in an "unsafe" mode. This turns off bounds checking for improved performance, at the cost of potentially opening your application up to memory correctness problems.

In general, it is highly recommended that you use the [`ByteBuffer`][bb] in its safe mode at all times.

For more details on the API of [`ByteBuffer`][bb], please see our API documentation, linked below.

##### Promises and Futures

One major difference between writing concurrent code and writing synchronous code is that not all actions will complete immediately. For example, when you write data on a channel, it is possible that the event loop will not be able to immediately flush that write out to the network. For this reason, SwiftNIO provides [`EventLoopPromise<T>`][elp] and [`EventLoopFuture<T>`][elf] to manage operations that complete *asynchronously*. These types are provided by the [NIOCore][module-core] module.

An [`EventLoopFuture<T>`][elf] is essentially a container for the return value of a function that will be populated *at some time in the future*. Each [`EventLoopFuture<T>`][elf] has a corresponding [`EventLoopPromise<T>`][elp], which is the object that the result will be put into. When the promise is succeeded, the future will be fulfilled.

If you had to poll the future to detect when it completed that would be quite inefficient, so [`EventLoopFuture<T>`][elf] is designed to have managed callbacks. Essentially, you can chain callbacks off the future that will be executed when a result is available. The [`EventLoopFuture<T>`][elf] will even carefully arrange the scheduling to ensure that these callbacks always execute on the event loop that initially created the promise, which helps ensure that you don't need too much synchronization around [`EventLoopFuture<T>`][elf] callbacks.

Another important topic for consideration is the difference between how the promise passed to `close` works as opposed to `closeFuture` on a [`Channel`][c]. For example, the promise passed into `close` will succeed after the [`Channel`][c] is closed down but before the [`ChannelPipeline`][cp] is completely cleared out. This will allow you to take action on the [`ChannelPipeline`][cp] before it is completely cleared out, if needed. If it is desired to wait for the [`Channel`][c] to close down and the [`ChannelPipeline`][cp] to be cleared out without any further action, then the better option would be to wait for the `closeFuture` to succeed.

There are several functions for applying callbacks to [`EventLoopFuture<T>`][elf], depending on how and when you want them to execute. Details of these functions is left to the API documentation.

#### Design Philosophy

SwiftNIO is designed to be a powerful tool for building networked applications and frameworks, but it is not intended to be the perfect solution for all levels of abstraction. SwiftNIO is tightly focused on providing the basic I/O primitives and protocol implementations at low levels of abstraction, leaving more expressive but slower abstractions to the wider community to build. The intention is that SwiftNIO will be a building block for server-side applications, not necessarily the framework those applications will use directly.

Applications that need extremely high performance from their networking stack may choose to use SwiftNIO directly in order to reduce the overhead of their abstractions. These applications should be able to maintain extremely high performance with relatively little maintenance cost. SwiftNIO also focuses on providing useful abstractions for this use-case, such that extremely high performance network servers can be built directly.

The core SwiftNIO repository will contain a few extremely important protocol implementations, such as HTTP, directly in tree. However, we believe that most protocol implementations should be decoupled from the release cycle of the underlying networking stack, as the release cadence is likely to be very different (either much faster or much slower). For this reason, we actively encourage the community to develop and maintain their protocol implementations out-of-tree. Indeed, some first-party SwiftNIO protocol implementations, including our TLS and HTTP/2 bindings, are developed out-of-tree!

## Topics

### Allocation Tests

- <doc:Running-Alloction-Counting-Tests>
- <doc:Debugging-Allocation-Regressions>


<!-- links -->

[repo-nio]: https://github.com/apple/swift-nio
[repo-nio-extras]: https://github.com/apple/swift-nio-extras
[repo-nio-http2]: https://github.com/apple/swift-nio-http2
[repo-nio-ssl]: https://github.com/apple/swift-nio-ssl
[repo-nio-transport-services]: https://github.com/apple/swift-nio-transport-services
[repo-nio-ssh]: https://github.com/apple/swift-nio-ssh

[module-core]: ./NIOCore
[module-posix]: ./NIOPosix
[module-embedded]: ./NIOEmbedded
[module-concurrency-helpers]: ./NIOConcurrencyHelpers
[module-foundation-compatibility]: ./NIOFoundationCompat
[module-http1]: ./NIOHTTP1
[module-tls]: ./NIOTLS
[module-websocket]: ./NIOWebSocket
[module-test-utilities]: ./NIOTestUtils
[module-filesystem]: ./_NIOFileSystem

[ch]: ./NIOCore/ChannelHandler
[c]: ./NIOCore/Channel
[chc]: ./NIOCore/ChannelHandlerContext
[ec]: ./NIOEmbedded/EmbeddedChannel
[el]: ./NIOCore/EventLoop
[eel]: ./NIOEmbedded/EmbeddedEventLoop
[elg]: ./NIOCore/EventLoopGroup
[bb]: ./NIOCore/ByteBuffer
[elf]: ./NIOCore/EventLoopFuture
[elp]: ./NIOCore/EventLoopPromise
[cp]: ./NIOCore/ChannelPipeline
[mtelg]: ./NIOPosix/MultiThreadedEventLoopGroup
[sb]: ./NIOPosix/ServerBootstrap
[cb]: ./NIOPosix/ClientBootstrap
[db]: ./NIOPosix/DatagramBootstrap
[pthreads]: https://en.wikipedia.org/wiki/POSIX_Threads
[kqueue]: https://en.wikipedia.org/wiki/Kqueue
[epoll]: https://en.wikipedia.org/wiki/Epoll

<!--
NIOCore NIOEmbedded NIOPosix NIOHTTP1 NIOFoundationCompat NIOWebSocket NIOConcurrencyHelpers NIOTLS NIOTestUtils
-->
