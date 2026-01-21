# NIOAsyncRuntime

NIOAsyncRuntime provides a lightweight implementation of `NIOPosix.MultiThreadedEventLoopGroup` (ie. AsyncEventLoopGroup) 
and `NIOPosix.NIOThreadPool` (ie. AsyncThreadPool)that can be used as a drop-in
replacement for the original implementations in NIOPosix, for platforms such as WASI that NIOPosix doesn't support.

NIOAsyncRuntime is powered by Swift Concurrency and avoids low-level operating system C API calls. This enables
compiling to WebAssembly using the [Swift SDK for WebAssembly](https://www.swift.org/documentation/articles/wasm-getting-started.html)

## Highlights

- Drop-in `MultiThreadedEventLoopGroup` and `NIOThreadPool` implementations that enable avoiding `NIOPosix` dependencies.
- Uses Swift Concurrency tasks under the hood.
- Matches the existing NIOPosix APIs, making adoption straightforward.

## Known Limitations

- NIOPosix currently provides significantly faster performance in benchmarks for heavy-load event enqueuing. See the benchmarks below for details.

# Getting Started

## Requirements

- Swift 6.0 or later toolchain
- Any platform supporting Swift Concurrency
- Minimum supported platforms: macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, WASI 0.1

## Swift Package Manager

### Using NIOAsyncRuntime + NIOPosix side-by-side
 
Use NIOAsyncRuntime only for platforms where NIOPosix is unsupported.

Add the package to your `Package.swift`:

```swift
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            // WASI targets use NIOAsyncRuntime
            .product(
                name: "NIOAsyncRuntime",
                package: "swift-nio",
                condition: .when(platforms: [.wasi])
            ),

            // NIOPosix is automatically elided for WASI platforms
            .product(
                name: "NIOPosix",
                package: "swift-nio",
            ),
        ]
    ),
]
```

## Importing

You can opt in to the async runtime or fall back to `NIOPosix` with a simple conditional import and type aliases.

```swift
#if canImport(NIOAsyncRuntime)
import NIOAsyncRuntime // Empty for non-WASI
typealias MultiThreadedEventLoopGroup = AsyncEventLoopGroup // If needed
typealias NIOThreadPool = AsyncThreadPool // If needed
#endif
import NIOPosix // <- Empty for WASI

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

```

# Usage Examples

## Event loops with `AsyncEventLoopGroup`

```swift
import protocol NIOCore.EventLoopGroup
import class NIOAsyncRuntime.AsyncEventLoopGroup

let group = AsyncEventLoopGroup()

let loop = group.next()
let future = loop.submit {
    "Hello World!"
}

future.whenSuccess { value in
    print(value)
}

// Shutdown when done
do {
    try await group.shutdownGracefully()
    print("Shutdown status: OK")
} catch {
    print("Shutdown status:", error)
}
```

## Thread pool work with `AsyncThreadPool`

```swift
import protocol NIOCore.EventLoopGroup
import class NIOAsyncRuntime.AsyncEventLoopGroup
import class NIOAsyncRuntime.AsyncThreadPool

let pool = AsyncThreadPool()
pool.start()

let loop = AsyncEventLoop()
let future = pool.runIfActive(eventLoop: loop) {
    return "Welcome to the Future!"
}

let result = try await future.get()
print("Result:", result)

// Clean up
do {
    try await loop.shutdownGracefully()
    try await pool.shutdownGracefully()
    print("Shutdown status: OK")
} catch {
    print("Shutdown status:", error)
}
```

# Benchmarks

NIOAsyncRuntime is currently significantly less performant than NIOPosix. Below are benchmark results run against both frameworks.

| Benchmark                                                |      NIOPosix     | NIOAsyncRuntime |
| -------------------------------------------------------- | ----------------: | --------------: |
| Jump to EL and back using actor with EL executor         |  **1.44x faster** |      1.00x      |
| Jump to EL and back using execute and unsafecontinuation |  **1.31x faster** |      1.00x      |
| MTELG.scheduleCallback(in:)                              | **11.71x faster** |      1.00x      |
| MTELG.scheduleTask(in:)                                  |  **4.06x faster** |      1.00x      |
| MTELG.immediateTasksThroughput                           |  **4.92x faster** |      1.00x      |
