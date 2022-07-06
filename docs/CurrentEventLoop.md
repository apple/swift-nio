# CurrentEventLoop

## Introduction

Many methods on `EventLoop`, `EventLoopFuture` and `Scheduled` take an escaping function type as an argument. 
Most of these function types do now need to conform to `Sendable` because the function may cross an isolation domain.
However, a common pattern in NIO programs guarantees that they do **not** cross an isolation domain. 
This PR makes it possible to encode this guarantee into the type system. 
The goal of this is not necessary to land the code but use it as starting point to talk about the semantics we want and need in the world of strict sendability checking. 
We also want to see if this problem can be and should be solved in a library or needs language support.

## Motivation

NIOs `ChannelPipeline` and other patterns which interact with the `ChannelPipeline` guarantee that each instance has one fixed `EventLoop`. 
Many async operations associated with a `ChannelPipeline` do also guarantee that they notify you on the associated `EventLoop`. 
NIO programs rely on these semantics for synchronization. 
These semantics are not encoded in the type system. Every `NIO` user needs to know where an `EventLoop`, `EventLoopFuture` or `Scheduled` came from to know if it is safe to access shared state without additional synchronization.

SwiftNIO has now fully adopted Sendable. 
Therefore all escaping function types need to conform to `Sendable` for almost all methods on `EventLoop`, `EventLoopFuture` and `Scheduled`. 
The function types need to conform to `Sendable` because they may not be executed on the current `EventLoop` and therefore cross an isolation domain.

Many NIO programs will now get false positive Sendable warnings in strict concurrency mode because of these new Sendable requirements. 
One good example with ~30 false positive Sendable warnings is `NIO`s own [`NIOHTTP1Server` example](https://github.com/apple/swift-nio/blob/main/Sources/NIOHTTP1Server/main.swift). 

## Proposed solution

This PR includes a new collection of non-Sendable wrapper types:

```swift
public struct CurrentEventLoop {
    public let wrapped: EventLoop
    [...]
}
public struct CurrentEventLoopPromise<Value> {
    public let wrapped: EventLoopPromise<Value>
    [...]
}
public struct CurrentEventLoopFuture<Value> {
    public let wrapped: EventLoopFuture<Value>
    [...]
}
public struct ScheduledOnCurrentEventLoop<T> {
    public let wrapped: Scheduled<T>
    [...]
}

```

Each type guarantees that their associated `EventLoop` is the current EventLoop i.e. `EventLoop.inEventLoop == true`. 
A `CurrentEventLoop` can be constructed from an `EventLoop` by calling `EventLoop.iKnowIAmOnThisEventLoop()` (naming suggestions welcome).

```swift
extension EventLoop {
    public func iKnowIAmOnThisEventLoop() -> CurrentEventLoop {
        self.preconditionInEventLoop()
        return .init(self)
    }
}
```

A precondition makes sure that this is actually the case at runtime. This check is only necessary during creation of the wrapper. 
As these types are non-Sendable, the compiler makes sure that an instance is never passed to a different isolation domain (e.g. `EventLoop` in our case). 
The other wrapper types can be constructed through similar named methods on their wrapped type.

These wrappers have almost the same interface as the types they wrap, but with two important differences: 

1. All methods take non-Sendable function types as arguments. 
This is safe as the functions passed to these methods are always executed on the same `EventLoop` as the method is called on and therefore does **not** cross an isolation domain.

2. Methods which return `EventLoop*` types, like `map(_:)` and `scheduleTask(in:_:)`, return their wrapped `CurrentEventLoop` equivalent. 
This even includes `flatMap(_:)` as the current implementation already hops to the `EventLoop` of `self` if necessary which in our case is the current `EventLoop`.

This allows users to capture local mutable state and non-Sendable types, like `ChannelContext`, in closures passed to these methods. 
User will still need to know if they are on the same event loop and explicitly call `iKnowIAmOnThisEventLoop()`. 
However, it gives them a tool to state that once and it will propagate through method chaining. 
It actually makes the code much safer as the precondition will crash the process instead of introducing a potential silent data race. 
The usual workaround to "silence" `Sendable` warnings/errors in the cases where we expect to be on the same `EventLoop` would involve unsafe constructs. 
We would otherwise use [`UnsafeTransfer` for each non-Sendable value](https://github.com/apple/swift-evolution/blob/main/proposals/0302-concurrent-value-and-concurrent-closures.md#adaptor-types-for-legacy-codebases) and [`UnsafeMutableTransferBox` for each local mutable variable](https://github.com/apple/swift-nio/blob/b99da5d3fee8ab155f4a7573aa04ae49820daaa0/Sources/NIOCore/NIOSendable.swift#L48-L63) as [we have already done in NIOs internals](https://github.com/apple/swift-nio/blob/0e2818bf866d5ff9b44c1619b86ecda8b9e86300/Sources/NIOCore/EventLoopFuture.swift#L1113). 
This is now no longer necessary in many cases.

## Detailed design

This PR includes an implementation of `CurrentEventLoop`, `CurrentEventLoopPromise`, `CurrentEventLoopFuture` and `ScheduledOnCurrentEventLoop`. 
The `NIOHTTP1Server` example was adapted to use `iKnowIAmOnThisEventLoop()` and friends to fix Sendable warnings.


## Source compatibility

In its current form, it is a purely additive change.

## Future direction 

### Replace `EventLoop` with `CurrentEventLoop` in our public API where we already guarantee being on the current `EventLoop`

We may want to replace the `EventLoop` returned by `ChannelContext.eventLoop` with `CurrentEventLoop`. 
Other places like `context.write*` could return a `CurrentEventLoopFuture` and many more. 
This would actually encode these isolation context guarantees into the type system but also break source compatibility because we change the return type. 
This will only be possible in a major release of NIO e.g. NIO 3.

### Adopt `CurrentEventLoop` in other APIs

Even after returning `CurrentEventLoop` from our API or using `iKnowIAmOnThisEventLoop()`, there is still one place in the `NIOHTTP1Server` examples which still emits Sendable diagnostics.
We make a call to `NonBlockingFileIO.readChunked` which has an interface that looks like this:

```swift
public struct NonBlockingFileIO: Sendable {
    public func readChunked(
        fileRegion: FileRegion,
        chunkSize: Int = NonBlockingFileIO.defaultChunkSize,
        allocator: ByteBufferAllocator,
        eventLoop: EventLoop,
        chunkHandler: @escaping @Sendable (ByteBuffer) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Void> {
        [...]
    }
    [...]
}
```

This is also a common pattern in NIO. We specify the `EventLoop` which `chunkHandler` will be called on through the `eventLoop` parameter. 
This is similar to a pattern found in many Apple Frameworks. 
There you can often defined the `DispatchQueue` a callback or a delegate is called on. 
[One example is `Network.framework`s `NWConnection.start(on:)` method](https://developer.apple.com/documentation/network/nwconnection/2998575-start) which we make use of too in `swift-nio-transport-services`. 

We could overload this method with a method which takes a `CurrentEventLoop` and drop the `Sendable` requirement on `chunkHandler`.