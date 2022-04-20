[![sswg:graduated|104x20](https://img.shields.io/badge/sswg-graduated-green.svg)](https://github.com/swift-server/sswg/blob/main/process/incubation.md#graduated-level)

# SwiftNIO

SwiftNIO is a cross-platform asynchronous event-driven network application framework
for rapid development of maintainable high performance protocol servers & clients.

It's like [Netty](https://netty.io), but written for Swift.

### Repository organization

The SwiftNIO project is split across multiple repositories:

Repository | NIO 2 (Swift 5.4+)
--- | ---
[https://github.com/apple/swift-nio][repo-nio] <br> SwiftNIO core | `from: "2.0.0"`
[https://github.com/apple/swift-nio-ssl][repo-nio-ssl] <br> TLS (SSL) support | `from: "2.0.0"`
[https://github.com/apple/swift-nio-http2][repo-nio-http2]<br> HTTP/2 support | `from: "1.0.0"`
[https://github.com/apple/swift-nio-extras][repo-nio-extras] <br>useful additions around SwiftNIO | `from: "1.0.0"`
[https://github.com/apple/swift-nio-transport-services][repo-nio-transport-services] <br> first-class support for macOS, iOS, tvOS, and watchOS | `from: "1.0.0"`
[https://github.com/apple/swift-nio-ssh][repo-nio-ssh] <br> SSH support | `.upToNextMinor(from: "0.2.0")`

NIO 2.29.0 and older support Swift 5.0+, NIO 2.39.0 and older support Swift 5.2+.

Within this repository we have a number of products that provide different functionality. This package contains the following products:

- `NIO`. This is an umbrella module exporting `NIOCore`, `NIOEmbedded` and `NIOPosix`.
- `NIOCore`. This provides the core abstractions and types for using SwiftNIO (see ["Conceptual Overview"](#conceptual-overview) for more details). Most NIO extension projects that provide things like new [`EventLoop`s][el] and [`Channel`s][c] or new protocol implementations should only need to depend on `NIOCore`.
- `NIOPosix`. This provides the primary [`EventLoopGroup`], [`EventLoop`][el], and [`Channel`s][c] for use on POSIX-based systems. This is our high performance core I/O layer. In general, this should only be imported by projects that plan to do some actual I/O, such as high-level protocol implementations or applications.
- `NIOEmbedded`. This provides [`EmbeddedChannel`][ec] and [`EmbeddedEventLoop`][eel], implementations of the `NIOCore` abstractions that provide fine-grained control over their execution. These are most often used for testing, but can also be used to drive protocol implementations in a way that is decoupled from networking altogether.
- `NIOConcurrencyHelpers`. This provides a few low-level concurrency primitives that are used by NIO implementations, such as locks and atomics.
- `NIOFoundationCompat`. This extends a number of NIO types for better interoperation with Foundation data types. If you are working with Foundation data types such as `Data`, you should import this.
- `NIOTLS`. This provides a few common abstraction types for working with multiple TLS implementations. Note that this doesn't provide TLS itself: please investigate [swift-nio-ssl][repo-nio-ssl] and [swift-nio-transport-services][repo-nio-transport-services] for concrete implementations.
- `NIOHTTP1`. This provides a low-level HTTP/1.1 protocol implementation.
- `NIOWebSocket`. This provides a low-level WebSocket protocol implementation.
- `NIOTestUtils`. This provides a number of helpers for testing projects that use SwiftNIO.

### Protocol Implementations

Below you can find a list of a few protocol implementations that are done with SwiftNIO. This is a non-exhaustive list of protocols that are either part of the SwiftNIO project or are accepted into the [SSWG](https://swift.org/server)'s incubation process. All of the libraries listed below do all of their I/O in a non-blocking fashion using SwiftNIO.

#### Low-level protocol implementations

Low-level protocol implementations are often a collection of [`ChannelHandler`][ch]s that implement a protocol but still require the user to have a good understanding of SwiftNIO. Often, low-level protocol implementations will then be wrapped in high-level libraries with a nicer, more user-friendly API.

Protocol | Client | Server | Repository | Module | Comment
--- |  --- | --- | --- | --- | ---
HTTP/1 | ✅| ✅ | [apple/swift-nio](https://github.com/apple/swift-nio) | [`NIOHTTP1`](https://apple.github.io/swift-nio/docs/current/NIOHTTP1/index.html) | official NIO project
HTTP/2 | ✅| ✅ | [apple/swift-nio-http2](https://github.com/apple/swift-nio-http2) | [`NIOHTTP2`](https://apple.github.io/swift-nio-http2/docs/current/NIOHTTP2/index.html) | official NIO project
WebSocket | ✅| ✅ | [apple/swift-nio](https://github.com/apple/swift-nio) | [`NIOWebSocket`](https://apple.github.io/swift-nio/docs/current/NIOWebSocket/index.html) | official NIO project
TLS | ✅ | ✅ | [apple/swift-nio-ssl](https://github.com/apple/swift-nio-ssl) | [`NIOSSL`](https://apple.github.io/swift-nio-ssl/docs/current/NIOSSL/index.html) | official NIO project
SSH | ✅ | ✅ | [apple/swift-nio-ssh][repo-nio-ssh] | _n/a_ | official NIO project


#### High-level implementations

High-level implementations are usually libraries that come with an API that doesn't expose SwiftNIO's [`ChannelPipeline`][cp] and can therefore be used with very little (or no) SwiftNIO-specific knowledge. The implementations listed below do still do all of their I/O in SwiftNIO and integrate really well with the SwiftNIO ecosystem.

Protocol | Client | Server | Repository | Module | Comment
--- |  --- | --- | --- | --- | ---
HTTP | ✅| ❌ | [swift-server/async-http-client](https://github.com/swift-server/async-http-client) | `AsyncHTTPClient` | SSWG community project
gRPC | ✅| ✅ | [grpc/grpc-swift](https://github.com/grpc/grpc-swift) | `GRPC` | also offers a low-level API; SSWG community project
APNS | ✅ | ❌ | [kylebrowning/APNSwift](https://github.com/kylebrowning/APNSwift) | `APNSwift` | SSWG community project
PostgreSQL | ✅ | ❌ | [vapor/postgres-nio](https://github.com/vapor/postgres-nio) | `PostgresNIO` | SSWG community project
Redis | ✅ | ❌ | [mordil/swift-redi-stack](https://gitlab.com/Mordil/swift-redi-stack) | `RediStack` | SSWG community project

### Supported Versions

### SwiftNIO 2
This is the current version of SwiftNIO and will be supported for the foreseeable future.

The latest released SwiftNIO 2 version supports Swift 5.4+. NIO 2.29.0 and older support Swift 5.0+, NIO 2.39.0 and older support Swift 5.2+.

### SwiftNIO 1
SwiftNIO 1 is considered end of life - it is strongly recommended that you move to a newer version.  The Core NIO team does not actively work on this version.  No new features will be added to this version but PRs which fix bugs or security vulnerabilities will be accepted until the end of May 2022.

If you have a SwiftNIO 1 application or library that you would like to migrate to SwiftNIO 2, please check out the [migration guide](docs/migration-guide-NIO1-to-NIO2.md) we prepared for you.

The latest released SwiftNIO 1 version supports Swift 4.0, 4.1, 4.2, and 5.0.

### Supported Platforms

SwiftNIO aims to support all of the platforms where Swift is supported. Currently, it is developed and tested on macOS and Linux, and is known to support the following operating system versions:

* Ubuntu 18.04+
* macOS 10.9+, iOS 7+; (macOS 10.14+, iOS 12+, tvOS 12+ or watchOS 6+ with [swift-nio-transport-services][repo-nio-transport-services])

### Compatibility

SwiftNIO follows [SemVer 2.0.0](https://semver.org/#semantic-versioning-200) with a separate document declaring [SwiftNIO's Public API](docs/public-api.md).

What this means for you is that you should depend on SwiftNIO with a version range that covers everything from the minimum SwiftNIO version you require up to the next major version.
In SwiftPM that can be easily done specifying for example `from: "2.0.0"` meaning that you support SwiftNIO in every version starting from 2.0.0 up to (excluding) 3.0.0.
SemVer and SwiftNIO's Public API guarantees should result in a working program without having to worry about testing every single version for compatibility.



## Conceptual Overview

SwiftNIO is fundamentally a low-level tool for building high-performance networking applications in Swift. It particularly targets those use-cases where using a "thread-per-connection" model of concurrency is inefficient or untenable. This is a common limitation when building servers that use a large number of relatively low-utilization connections, such as HTTP servers.

To achieve its goals SwiftNIO extensively uses "non-blocking I/O": hence the name! Non-blocking I/O differs from the more common blocking I/O model because the application does not wait for data to be sent to or received from the network: instead, SwiftNIO asks for the kernel to notify it when I/O operations can be performed without waiting.

SwiftNIO does not aim to provide high-level solutions like, for example, web frameworks do. Instead, SwiftNIO is focused on providing the low-level building blocks for these higher-level applications. When it comes to building a web application, most users will not want to use SwiftNIO directly: instead, they'll want to use one of the many great web frameworks available in the Swift ecosystem. Those web frameworks, however, may choose to use SwiftNIO under the covers to provide their networking support.

The following sections will describe the low-level tools that SwiftNIO provides, and provide a quick overview of how to work with them. If you feel comfortable with these concepts, then you can skip right ahead to the other sections of this README.

### Basic Architecture

The basic building blocks of SwiftNIO are the following 8 types of objects:

- [`EventLoopGroup`][elg], a protocol, provided by `NIOCore`.
- [`EventLoop`][el], a protocol, provided by `NIOCore`.
- [`Channel`][c], a protocol, provided by `NIOCore`.
- [`ChannelHandler`][ch], a protocol, provided by `NIOCore`.
- `Bootstrap`, several related structures, provided by `NIOCore`.
- [`ByteBuffer`][bb], a struct, provided by `NIOCore`.
- [`EventLoopFuture`][elf], a generic class, provided by `NIOCore`.
- [`EventLoopPromise`][elp], a generic struct, provided by `NIOCore`.

All SwiftNIO applications are ultimately constructed of these various components.

#### EventLoops and EventLoopGroups

The basic I/O primitive of SwiftNIO is the event loop. The event loop is an object that waits for events (usually I/O related events, such as "data received") to happen and then fires some kind of callback when they do. In almost all SwiftNIO applications there will be relatively few event loops: usually only one or two per CPU core the application wants to use. Generally speaking event loops run for the entire lifetime of your application, spinning in an endless loop dispatching events.

Event loops are gathered together into event loop *groups*. These groups provide a mechanism to distribute work around the event loops. For example, when listening for inbound connections the listening socket will be registered on one event loop. However, we don't want all connections that are accepted on that listening socket to be registered with the same event loop, as that would potentially overload one event loop while leaving the others empty. For that reason, the event loop group provides the ability to spread load across multiple event loops.

In SwiftNIO today there is one [`EventLoopGroup`][elg] implementation, and two [`EventLoop`][el] implementations. For production applications there is the [`MultiThreadedEventLoopGroup`][mtelg], an [`EventLoopGroup`][elg] that creates a number of threads (using the POSIX [`pthreads`][pthreads] library) and places one `SelectableEventLoop` on each one. The `SelectableEventLoop` is an event loop that uses a selector (either [`kqueue`][kqueue] or [`epoll`][epoll] depending on the target system) to manage I/O events from file descriptors and to dispatch work. These [`EventLoop`s][el] and [`EventLoopGroup`s][elg] are provided by the `NIOPosix` module. Additionally, there is the [`EmbeddedEventLoop`][eel], which is a dummy event loop that is used primarily for testing purposes, provided by the `NIOEmbedded` module.

[`EventLoop`][el]s have a number of important properties. Most vitally, they are the way all work gets done in SwiftNIO applications. In order to ensure thread-safety, any work that wants to be done on almost any of the other objects in SwiftNIO must be dispatched via an [`EventLoop`][el]. [`EventLoop`][el] objects own almost all the other objects in a SwiftNIO application, and understanding their execution model is critical for building high-performance SwiftNIO applications.

#### Channels, Channel Handlers, Channel Pipelines, and Channel Contexts

While [`EventLoop`][el]s are critical to the way SwiftNIO works, most users will not interact with them substantially beyond asking them to create [`EventLoopPromise`][elp]s and to schedule work. The parts of a SwiftNIO application most users will spend the most time interacting with are [`Channel`][c]s and [`ChannelHandler`][ch]s.

Almost every file descriptor that a user interacts with in a SwiftNIO program is associated with a single [`Channel`][c]. The [`Channel`][c] owns this file descriptor, and is responsible for managing its lifetime. It is also responsible for processing inbound and outbound events on that file descriptor: whenever the event loop has an event that corresponds to a file descriptor, it will notify the [`Channel`][c] that owns that file descriptor.

[`Channel`][c]s by themselves, however, are not useful. After all, it is a rare application that doesn't want to do anything with the data it sends or receives on a socket! So the other important part of the [`Channel`][c] is the [`ChannelPipeline`][cp].

A [`ChannelPipeline`][cp] is a sequence of objects, called [`ChannelHandler`][ch]s, that process events on a [`Channel`][c]. The [`ChannelHandler`][ch]s process these events one after another, in order, mutating and transforming events as they go. This can be thought of as a data processing pipeline; hence the name [`ChannelPipeline`][cp].

All [`ChannelHandler`][ch]s are either Inbound or Outbound handlers, or both. Inbound handlers process "inbound" events: events like reading data from a socket, reading socket close, or other kinds of events initiated by remote peers. Outbound handlers process "outbound" events, such as writes, connection attempts, and local socket closes.

Each handler processes the events in order. For example, read events are passed from the front of the pipeline to the back, one handler at a time, while write events are passed from the back of the pipeline to the front. Each handler may, at any time, generate either inbound or outbound events that will be sent to the next handler in whichever direction is appropriate. This allows handlers to split up reads, coalesce writes, delay connection attempts, and generally perform arbitrary transformations of events.

In general, [`ChannelHandler`][ch]s are designed to be highly re-usable components. This means they tend to be designed to be as small as possible, performing one specific data transformation. This allows handlers to be composed together in novel and flexible ways, which helps with code reuse and encapsulation.

[`ChannelHandler`][ch]s are able to keep track of where they are in a [`ChannelPipeline`][cp] by using a [`ChannelHandlerContext`][chc]. These objects contain references to the previous and next channel handler in the pipeline, ensuring that it is always possible for a [`ChannelHandler`][ch] to emit events while it remains in a pipeline.

SwiftNIO ships with many [`ChannelHandler`][ch]s built in that provide useful functionality, such as HTTP parsing. In addition, high-performance applications will want to provide as much of their logic as possible in [`ChannelHandler`][ch]s, as it helps avoid problems with context switching.

Additionally, SwiftNIO ships with a few [`Channel`][c] implementations. In particular, it ships with `ServerSocketChannel`, a [`Channel`][c] for sockets that accept inbound connections; `SocketChannel`, a [`Channel`][c] for TCP connections; and `DatagramChannel`, a [`Channel`][c] for UDP sockets. All of these are provided by the `NIOPosix` module. It also provides[`EmbeddedChannel`][ec], a [`Channel`][c] primarily used for testing, provided by the `NIOEmbedded` module.

##### A Note on Blocking

One of the important notes about [`ChannelPipeline`][cp]s is that they are thread-safe. This is very important for writing SwiftNIO applications, as it allows you to write much simpler [`ChannelHandler`][ch]s in the knowledge that they will not require synchronization.

However, this is achieved by dispatching all code on the [`ChannelPipeline`][cp] on the same thread as the [`EventLoop`][el]. This means that, as a general rule, [`ChannelHandler`][ch]s **must not** call blocking code without dispatching it to a background thread. If a [`ChannelHandler`][ch] blocks for any reason, all [`Channel`][c]s attached to the parent [`EventLoop`][el] will be unable to progress until the blocking call completes.

This is a common concern while writing SwiftNIO applications. If it is useful to write code in a blocking style, it is highly recommended that you dispatch work to a different thread when you're done with it in your pipeline.

#### Bootstrap

While it is possible to configure and register [`Channel`][c]s with [`EventLoop`][el]s directly, it is generally more useful to have a higher-level abstraction to handle this work.

For this reason, SwiftNIO ships a number of `Bootstrap` objects whose purpose is to streamline the creation of channels. Some `Bootstrap` objects also provide other functionality, such as support for Happy Eyeballs for making TCP connection attempts.

Currently SwiftNIO ships with three `Bootstrap` objects in the `NIOPosix` module: [`ServerBootstrap`](https://apple.github.io/swift-nio/docs/current/NIOPosix/Classes/ServerBootstrap.html), for bootstrapping listening channels; [`ClientBootstrap`](https://apple.github.io/swift-nio/docs/current/NIOPosix/Classes/ClientBootstrap.html), for bootstrapping client TCP channels; and [`DatagramBootstrap`](https://apple.github.io/swift-nio/docs/current/NIOPosix/Classes/DatagramBootstrap.html) for bootstrapping UDP channels.

#### ByteBuffer

The majority of the work in a SwiftNIO application involves shuffling buffers of bytes around. At the very least, data is sent and received to and from the network in the form of buffers of bytes. For this reason it's very important to have a high-performance data structure that is optimized for the kind of work SwiftNIO applications perform.

For this reason, SwiftNIO provides [`ByteBuffer`][bb], a fast copy-on-write byte buffer that forms a key building block of most SwiftNIO applications. This type is provided by the `NIOCore` module.

[`ByteBuffer`][bb] provides a number of useful features, and in addition provides a number of hooks to use it in an "unsafe" mode. This turns off bounds checking for improved performance, at the cost of potentially opening your application up to memory correctness problems.

In general, it is highly recommended that you use the [`ByteBuffer`][bb] in its safe mode at all times.

For more details on the API of [`ByteBuffer`][bb], please see our API documentation, linked below.

#### Promises and Futures

One major difference between writing concurrent code and writing synchronous code is that not all actions will complete immediately. For example, when you write data on a channel, it is possible that the event loop will not be able to immediately flush that write out to the network. For this reason, SwiftNIO provides [`EventLoopPromise<T>`][elp] and [`EventLoopFuture<T>`][elf] to manage operations that complete *asynchronously*. These types are provided by the `NIOCore` module.

An [`EventLoopFuture<T>`][elf] is essentially a container for the return value of a function that will be populated *at some time in the future*. Each [`EventLoopFuture<T>`][elf] has a corresponding [`EventLoopPromise<T>`][elp], which is the object that the result will be put into. When the promise is succeeded, the future will be fulfilled.

If you had to poll the future to detect when it completed that would be quite inefficient, so [`EventLoopFuture<T>`][elf] is designed to have managed callbacks. Essentially, you can hang callbacks off the future that will be executed when a result is available. The [`EventLoopFuture<T>`][elf] will even carefully arrange the scheduling to ensure that these callbacks always execute on the event loop that initially created the promise, which helps ensure that you don't need too much synchronization around [`EventLoopFuture<T>`][elf] callbacks.

Another important topic for consideration is the difference between how the promise passed to `close` works as opposed to `closeFuture` on a [`Channel`][c]. For example, the promise passed into `close` will succeed after the [`Channel`][c] is closed down but before the [`ChannelPipeline`][cp] is completely cleared out. This will allow you to take action on the [`ChannelPipeline`][cp] before it is completely cleared out, if needed. If it is desired to wait for the [`Channel`][c] to close down and the [`ChannelPipeline`][cp] to be cleared out without any further action, then the better option would be to wait for the `closeFuture` to succeed.

There are several functions for applying callbacks to [`EventLoopFuture<T>`][elf], depending on how and when you want them to execute. Details of these functions is left to the API documentation.

### Design Philosophy

SwiftNIO is designed to be a powerful tool for building networked applications and frameworks, but it is not intended to be the perfect solution for all levels of abstraction. SwiftNIO is tightly focused on providing the basic I/O primitives and protocol implementations at low levels of abstraction, leaving more expressive but slower abstractions to the wider community to build. The intention is that SwiftNIO will be a building block for server-side applications, not necessarily the framework those applications will use directly.

Applications that need extremely high performance from their networking stack may choose to use SwiftNIO directly in order to reduce the overhead of their abstractions. These applications should be able to maintain extremely high performance with relatively little maintenance cost. SwiftNIO also focuses on providing useful abstractions for this use-case, such that extremely high performance network servers can be built directly.

The core SwiftNIO repository will contain a few extremely important protocol implementations, such as HTTP, directly in tree. However, we believe that most protocol implementations should be decoupled from the release cycle of the underlying networking stack, as the release cadence is likely to be very different (either much faster or much slower). For this reason, we actively encourage the community to develop and maintain their protocol implementations out-of-tree. Indeed, some first-party SwiftNIO protocol implementations, including our TLS and HTTP/2 bindings, are developed out-of-tree!

## Documentation

 - [API documentation](https://apple.github.io/swift-nio/docs/current/NIO/index.html)

## Example Usage

There are currently several example projects that demonstrate how to use SwiftNIO.

- **chat client** https://github.com/apple/swift-nio/tree/main/Sources/NIOChatClient
- **chat server** https://github.com/apple/swift-nio/tree/main/Sources/NIOChatServer
- **echo client** https://github.com/apple/swift-nio/tree/main/Sources/NIOEchoClient
- **echo server** https://github.com/apple/swift-nio/tree/main/Sources/NIOEchoServer
- **UDP echo client** https://github.com/apple/swift-nio/tree/main/Sources/NIOUDPEchoClient
- **UDP echo server** https://github.com/apple/swift-nio/tree/main/Sources/NIOUDPEchoServer
- **HTTP client** https://github.com/apple/swift-nio/tree/main/Sources/NIOHTTP1Client
- **HTTP server** https://github.com/apple/swift-nio/tree/main/Sources/NIOHTTP1Server
- **WebSocket client** https://github.com/apple/swift-nio/tree/main/Sources/NIOWebSocketClient
- **WebSocket server** https://github.com/apple/swift-nio/tree/main/Sources/NIOWebSocketServer

To build & run them, run following command, replace TARGET_NAME with the folder name under `./Sources`

```bash
swift run TARGET_NAME
```

For example, to run NIOHTTP1Server, run following command:

```bash
swift run NIOHTTP1Server
```

## Getting Started

SwiftNIO primarily uses [SwiftPM](https://swift.org/package-manager/) as its build tool, so we recommend using that as well. If you want to depend on SwiftNIO in your own project, it's as simple as adding a `dependencies` clause to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0")
]
```

and then adding the appropriate SwiftNIO module(s) to your target dependencies.
The syntax for adding target dependencies differs slightly between Swift
versions. For example, if you want to depend on the `NIOCore`, `NIOPosix` and 
`NIOHTTP1` modules, specify the following dependencies:

#### Swift 5.4 and newer (`swift-tools-version:5.4`)

    dependencies: [.product(name: "NIOCore", package: "swift-nio"),
                   .product(name: "NIOPosix", package: "swift-nio"),
                   .product(name: "NIOHTTP1", package: "swift-nio")]

### Using Xcode Package support

If your project is set up as an Xcode project and you're using Xcode 11+, you can add SwiftNIO as a dependency to your
Xcode project by clicking File -> Swift Packages -> Add Package Dependency. In the upcoming dialog, please enter
`https://github.com/apple/swift-nio.git` and click Next twice. Finally, select the targets you are planning to use (for
example `NIOCore`, `NIOHTTP1`, and `NIOFoundationCompat`) and click finish. Now will be able to `import NIOCore` (as well as all
the other targets you have selected) in your project.

To work on SwiftNIO itself, or to investigate some of the demonstration applications, you can clone the repository directly and use SwiftPM to help build it. For example, you can run the following commands to compile and run the example echo server:

```bash
swift build
swift test
swift run NIOEchoServer
```

To verify that it is working, you can use another shell to attempt to connect to it:

```bash
echo "Hello SwiftNIO" | nc localhost 9999
```

If all goes well, you'll see the message echoed back to you.

To work on SwiftNIO in Xcode 11+, you can just open the `Package.swift`
file in Xcode and use Xcode's support for SwiftPM Packages.

If you want to develop SwiftNIO with Xcode 10, you have to generate an Xcode project:

```bash
swift package generate-xcodeproj
```

### An alternative: using `docker-compose`

Alternatively, you may want to develop or test with `docker-compose`.

First make sure you have [Docker](https://www.docker.com/community-edition) installed, next run the following commands:

- `docker-compose -f docker/docker-compose.yaml run test`

  Will create a base image with Swift runtime and other build and test dependencies, compile SwiftNIO and run the unit and integration tests

- `docker-compose -f docker/docker-compose.yaml up echo`

  Will create a base image, compile SwiftNIO, and run a sample `NIOEchoServer` on
  `localhost:9999`. Test it by `echo Hello SwiftNIO | nc localhost 9999`.

- `docker-compose -f docker/docker-compose.yaml up http`

  Will create a base image, compile SwiftNIO, and run a sample `NIOHTTP1Server` on
  `localhost:8888`. Test it by `curl http://localhost:8888`

- `docker-compose -f docker/docker-compose.yaml -f docker/docker-compose.2004.54.yaml run test`

  Will create a base image using Ubuntu 20.04 and swift 5.4, compile SwiftNIO and run the unit and integration tests.  Files exist for other ubuntu and swift versions in the docker directory.


## Developing SwiftNIO

*Note*: This section is only relevant if you would like to develop SwiftNIO yourself. You can ignore the information here if you just want to use SwiftNIO as a SwiftPM package.

For the most part, SwiftNIO development is as straightforward as any other SwiftPM project. With that said, we do have a few processes that are worth understanding before you contribute. For details, please see `CONTRIBUTING.md` in this repository.

### Prerequisites

SwiftNIO's `main` branch is the development branch for the next releases of SwiftNIO 2, it's Swift 5-only.

To be able to compile and run SwiftNIO and the integration tests, you need to
have a few prerequisites installed on your system.

#### macOS

- Xcode 11.4 or newer, Xcode 12 recommended.

### Linux

- Swift 5.2, 5.3, or 5.4 from [swift.org/download](https://swift.org/download/#releases). We always recommend to use the latest released version.
- netcat (for integration tests only)
- lsof (for integration tests only)
- shasum (for integration tests only)

#### Ubuntu 18.04

```
# install swift tarball from https://swift.org/downloads
apt-get install -y git curl libatomic1 libxml2 netcat-openbsd lsof perl
```


### Fedora 28+

```
dnf install swift-lang /usr/bin/nc /usr/bin/lsof /usr/bin/shasum
```

[ch]: https://apple.github.io/swift-nio/docs/current/NIOCore/Protocols/ChannelHandler.html
[c]: https://apple.github.io/swift-nio/docs/current/NIOCore/Protocols/Channel.html
[chc]: https://apple.github.io/swift-nio/docs/current/NIOCore/Classes/ChannelHandlerContext.html
[ec]: https://apple.github.io/swift-nio/docs/current/NIOCore/Classes/EmbeddedChannel.html
[el]: https://apple.github.io/swift-nio/docs/current/NIOCore/Protocols/EventLoop.html
[eel]: https://apple.github.io/swift-nio/docs/current/NIOCore/Classes/EmbeddedEventLoop.html
[elg]: https://apple.github.io/swift-nio/docs/current/NIOCore/Protocols/EventLoopGroup.html
[bb]: https://apple.github.io/swift-nio/docs/current/NIOCore/Structs/ByteBuffer.html
[elf]: https://apple.github.io/swift-nio/docs/current/NIOCore/Classes/EventLoopFuture.html
[elp]: https://apple.github.io/swift-nio/docs/current/NIOCore/Structs/EventLoopPromise.html
[cp]: https://apple.github.io/swift-nio/docs/current/NIOCore/Classes/ChannelPipeline.html
[mtelg]: https://apple.github.io/swift-nio/docs/current/NIOPosix/Classes/MultiThreadedEventLoopGroup.html
[pthreads]: https://en.wikipedia.org/wiki/POSIX_Threads
[kqueue]: https://en.wikipedia.org/wiki/Kqueue
[epoll]: https://en.wikipedia.org/wiki/Epoll
[repo-nio]: https://github.com/apple/swift-nio
[repo-nio-extras]: https://github.com/apple/swift-nio-extras
[repo-nio-http2]: https://github.com/apple/swift-nio-http2
[repo-nio-ssl]: https://github.com/apple/swift-nio-ssl
[repo-nio-transport-services]: https://github.com/apple/swift-nio-transport-services
[repo-nio-ssh]: https://github.com/apple/swift-nio-ssh

### Speeding up testing
It's possible to run the test suite in parallel, it can save significant time if you have a larger multi-core machine, just add `--parallel` when running the tests. This can speed up the run time of the test suite by 30x or more.

```
swift test --parallel
```
