# NIO 1 to NIO 2 migration guide

This migration guide is our recommendation to migrate from NIO 1 to NIO 2. None of the steps apart from changing your `Package.swift` and fixing the errors is actually required but this might help you complete the migration as fast as possible. For the NIO repositories and some example projects, we had really good success in migrating them fairly pain-free.

This repository also contains a fairly complete list of public [API changes](https://github.com/apple/swift-nio/blob/main/docs/public-api-changes-NIO1-to-NIO2.md) from NIO 1 to NIO 2.

## Step 1: A warning-free compile on NIO 1 with Swift 5

To start with, we highly recommend to first get your project to compile warning-free with NIO 1 on Swift 5. The reason is that some of the warnings you might get are the result of deprecation in NIO 1 and deprecated NIO 1 API has been fully removed in NIO 2.

For macOS, download Xcode 10, beta 3 or better and you're good to go. On Linux, use a very recent Swift 5.0 snapshot.

## Step 2: Update your NIO dependencies

Update the NIO packages you use to include the following versions.

- `swift-nio`: `.package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0")`
- `swift-nio-ssl`: `.package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.0.0")`
- `swift-nio-extras`: `.package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.0.0")`
- `swift-nio-http2`: `.package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.0.0")`
- `swift-nio-transport-services`: `.package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.0.0")`

After you changes your `Package.swift`, run `swift package update`.

## Step 3: `ctx` to `context`

The NIO community has [correctly](https://swift.org/documentation/api-design-guidelines/#avoid-abbreviations) [pointed](https://github.com/apple/swift-nio/issues/663#issuecomment-442013880) [out](https://github.com/apple/swift-nio/issues/483) that the use of `ctx` for the `ChannelHandlerContext` variables feels alien in Swift. We agree with this and have decided that despite the breakage it will cause, we shall rename all mentions of `ctx` to `context`. Unfortunately, that means that every `ChannelHandler` in existence needs a change. To make it worse, `ChannelHandler`s have default implementations for all events which means if you have a `ChannelHandler` method that still uses `ctx`, your code will still compile but the method will never be called because its first parameter is now named `context`.

Therefore, do yourself a favour and start the conversion from NIO 1 to NIO 2 by running the following command in the root of your package:

```bash
# if you're developing on macOS / BSD
find . -name '*.swift' -type f | while read line; do sed -E -i '' 's/([^"])[[:<:]]ctx[[:>:]]([^"])/\1context\2/g' "$line"; done
```

```bash
# if you're developing on Linux
find . -name '*.swift' -type f | while read line; do sed -E -i 's/([^"])\<ctx\>([^"])/\1context\2/g' "$line";  done
```

What these unwieldy commands do is replace `ctx` if it appears as its own word with `context` in all `.swift` files under the current directory. For the NIO packages themselves that was all that was needed for this huge change.

## Step 4: Use `_NIO1APIShims`

The goal of the `_NIO1APIShims` module (which is _not_ public API and is also untested) is to help you with all the small renames we have done for NIO 2. We recommend to follow these steps to make as much use of automation as possible as possible:

1. in your `Package.swift`, add `_NIO1APIShims` to your target's `dependencies:` list in all places that use any of the NIO modules. So for example `dependencies: ["NIO", "SomethingElse"]` should become `dependencies: ["NIO", "_NIO1APIShims", "SomethingElse"]`
2. add `import _NIO1APIShims` to all files where you `import NIO` or any of the other NIO modules like `import NIOHTTP1`. The following command will list all such files:
  `find . -name '*.swift' -type f | while read line; do if grep -q "import NIO" "$line"; then echo "$line"; fi; done`
3. fix all remaining compile errors, if there are any
4. apply all the compiler-suggested fixits, in Xcode you can
   1. Press `⌘'` to Jump to Next Issue
   2. Press `^⎇⌘F` to Fix All Issues in the current file
   3. Go back to 4.1 (jump to next issue) until you've gone through all the files and applied all the fixits
5. fix remaining warnings manually
6. remove all `import _NIO1APIShims` imports and all `_NIO1APIShims` mentions in your `Package.swift`

## Step 5: Require Swift 5 and NIO 2

NIO 2 only supports Swift 5 so after the migration you should change the first line of your `Package.swift` to read `// swift-tools-version:5.0`. That will also allow you to use all the great new features Swift Package Manager added in recent releases.

## Step 6: Watch out for more subtle changes

- Make sure you close your `Channel` if there's an unhandled error. Usually, the right thing to do is to invoke `context.close(promise: nil)` when `errorCaught` is invoked on your last `ChannelHandler`. Of course, handle all the errors you know you can handle but `close` on all others. This has always been true for NIO 1 too but in NIO 2 we have removed some of the automatic `Channel` closes in the `HTTPDecoder`s and `ByteToMessageDecoder`s have been removed. Why have they been removed? So a user can opt out of the automatic closure.
- If you have a `ByteToMessageDecoder` or a `MessageToByteEncoder`, you will now need to wrap them before adding them to the pipeline. For example:

```swift
    channel.pipeline.addHandler(ByteToMessageHandler(MyExampleDecoder())).flatMap {
        channel.pipeline.addHandler(MessageToByteHandler(MyExampleEncoder()))
    }
```
- Apart from this, most `ByteToMessageDecoder`s should continue to work. There is however one more subtle change: In SwiftNIO 1, you could (illegally) intercept arbitrary `ChannelInboundHandler` or `ChannelOutboundHandler` events in `ByteToMessageHandler`s. This did never work correctly (because the `ByteToMessageDecoder` driver would then not receive those events anymore). In SwiftNIO 2 this is fixed and you won't receive any of the standard `ChannelHandler` events in `ByteToMessageDecoder`s anymore.
