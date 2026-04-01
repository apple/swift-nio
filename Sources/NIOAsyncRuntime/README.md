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
- `AsyncEventLoop` has a scalability limit when a single process enqueues millions of long-delay `scheduleTask(in:)` calls under memory-constrained Linux CI environments. This is not representative of normal workloads, but can manifest in benchmarks. See the benchmarks section below for details.

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

## Performance vs NIOPosix

NIOAsyncRuntime is currently significantly less performant than NIOPosix. Below are benchmark results run against both frameworks.

| Benchmark                                                |      NIOPosix     | NIOAsyncRuntime |
| -------------------------------------------------------- | ----------------: | --------------: |
| Jump to EL and back using actor with EL executor         |  **1.44x faster** |      1.00x      |
| Jump to EL and back using execute and unsafecontinuation |  **1.31x faster** |      1.00x      |
| MTELG.scheduleCallback(in:)                              | **11.71x faster** |      1.00x      |
| MTELG.scheduleTask(in:)                                  |  **4.06x faster** |      1.00x      |
| MTELG.immediateTasksThroughput                           |  **4.92x faster** |      1.00x      |

## Scalability limitations in `MTELG.scheduleTask(in:_:)`

The benchmark case `NIOAsyncRuntimeBenchmarks:MTELG.scheduleTask(in:_:)` creates a synthetic stress profile by repeatedly scheduling far-future tasks (`.hours(1)`) at high volume.

At `.mega` scale with `maxIterations: 5`, this benchmark can enqueue millions of scheduled tasks in a single run. In constrained Linux CI environments (for example, 2 GB container memory), the benchmark process may terminate (`WaitPIDError`, `error code [9]`). This indicates a scalability limit for this specific synthetic pattern. The behavior has been observed on Linux with Swift 6.1 and Swift 6.2. In local macOS arm64 testing, including `.mega` runs, this crash was not reproduced.

Expected operating envelope:

- This limitation is primarily relevant to synthetic stress levels in the millions of scheduled operations per run.
- The `.kilo` scale setting keeps this benchmark in a stable range for CI while still exercising feature parity behavior.
- Based on current validation, this issue appears specific to constrained Linux benchmark environments and was not reproducible on macOS.
- Normal service workloads are expected to remain well below this stress level and are not expected to encounter this failure mode.

This scalability target is currently out of scope and would likely require significant implementation changes. To keep CI reliable while preserving parity coverage, `NIOAsyncRuntimeBenchmarks.MTELG.scheduleTask(in:_:)` uses `.kilo`, while `NIOPosix` remains at `.mega`.

To reproduce locally in a 2 GB constrained Linux container (Swift 6.1), use the following command:

```bash
# First, temporarily change:
# Benchmarks/Benchmarks/NIOAsyncRuntimeBenchmarks/Benchmarks.swift
# benchmark "MTELG.scheduleTask(in:_:)"
# from: scalingFactor: .kilo
# to:   scalingFactor: .mega
#
# Then run the following command:

docker run --rm --memory=2g --memory-swap=2g -v "$PWD":/swift-nio -w /swift-nio swift:6.1-jammy bash -lc '
set -uo pipefail
export HOME=/tmp/home
mkdir -p "$HOME"

apt-get update -y -q
apt-get install -y -q libjemalloc-dev

swift package --package-path Benchmarks --disable-sandbox benchmark thresholds check \
    --target NIOAsyncRuntimeBenchmarks \
    --filter "MTELG\\.scheduleTask\\(in:_:\\)" \
    --format metricP90AbsoluteThresholds
'
```
