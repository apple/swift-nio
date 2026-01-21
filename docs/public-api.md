# SwiftNIO 2 Public API

The SwiftNIO project (which includes all of `github.com/apple/swift-nio*`) aims to follow [SemVer 2.0.0](https://semver.org/spec/v2.0.0.html) which requires projects to declare a public API. This document along with the [API documentation](https://swiftpackageindex.com/apple/swift-nio/main/documentation) declare SwiftNIO's API.

## What are acceptable uses of NIO's Public API

### 1. Using NIO types, methods, and modules

It is acceptable and expected to use any exported type and call any exported method from the `NIO*` modules unless the type or function name start with an underscore (`_`). For `init`s this includes the first parameter's name.

##### What's the point of this restriction?

If we prefix something with an underscore or put it into one of NIO's internal modules, we can't commit to an API for it and don't expect users to ever use this. Also, there might be different underscored functions/types depending on the platform.

##### Examples

 - ✅ `channel.close(promise: nil)`
 - ❌ `channel._channelCore.flush0()`, underscored property
 - ❌ `import CNIOAtomics`, module name doesn't start with NIO
 - ❌ `ByteBuffer(_enableSuperSpecialAllocationMode: true)`, as the initialiser's first argument is underscored

---

### 2. Conforming NIO types to protocols

It is acceptable to conform NIO types to protocols _you control_, i.e. a protocol in _your codebase_. It is not acceptable to conform any NIO types to protocols in the standard library or outside of your control.

##### What's the point of this restriction?

NIO in a later version may conform its type to said protocol, or the package that provides the protocol may conform the NIO type to _their_ protocol.

##### Examples

  - ✅ `extension EventLoopFuture: MyOwnProtocol { ... }`, assuming `MyOwnProtocol` lives in your codebase
  - ❌ `extension EventLoopFuture: DebugStringConvertible { ... }`, `DebugStringConvertible` is a standard library protocol

---

### 3. Conforming your types to NIO protocols

It is acceptable to conform _your own types_ to NIO protocols but it is not acceptable to conform types you do not control to NIO protocols.

##### What's the point of this restriction?

NIO in a later version might add this conformance or the owner of the type may add the conformance.

##### Examples

  - ✅ `extension MyHandler: ChannelHandler { ... }`
  - ❌ `extension Array: EventLoopGroup where Element: EventLoop { ... }`, as `Array` lives in the standard library

---

### 4. Extending NIO types

It is acceptable to extend NIO types with `public` methods/properties that either use one of your types as a non-default argument or are prefixed in a way that prevents clashes. Adding `private`/`internal` methods/properties is always acceptable.

#### What's the point of these restrictions?

NIO might later add a member function/property with the same signature as yours.

##### Examples

  - ✅ `extension ByteBuffer { public mutating func readMyType(at: Int) -> MyType {...} }`, acceptable because it returns a `MyType`
  - ✅ `extension ByteBuffer { public mutating func myProjectReadInteger(at: Int) -> Int {...} } `, acceptable because prefixed with `myProject`
  - ✅ `extension ByteBuffer { internal mutating func readFloat(at: Int) -> Float {...} }`, acceptable even though `Float` is not in your control because the function is `internal`
  - ❌ `extension ByteBuffer { public mutating func readBool(at: Int) -> Bool {...} }`, because `Bool` is a standard library type not in your control


## Promises the NIO team make

Before releasing a new major version, i.e. SwiftNIO 3.0.0 we promise the following:

### 1. No global namespace additions that aren't prefixed

In a minor or patch version, all global types/modules/functions that we will add will have `NIO*`/`nio*`/`CNIO*`/`cnio*`/`c_nio*` prefixes, this includes C symbols that are visible to others. Be aware that we don't control the exact versions of the system libraries installed on your system so we can't make any guarantees about the symbols exported by the system libraries we depend on.


##### What does this mean concretely?

- ✅ We might add a new global type called `NIOJetPack`.
- ✅ We might add a new module called `NIOHelpers`.
- ✅ We might add a new global functions called `nioRun` (very unlikely) or `c_nio_SSL_write` (more likely).
- ❌ We will not add a global new type called `Tomato`.
- ❌ We will not add a new module called `Helpers`.
- ❌ We will not add a new global function called `SSL_write`.
- ❌ We will not add a new system library dependency without a new major version.

#### Why is this useful to you?

Let's assume your application is composed of three modules:

1. `NIO`, which in version 2.0.0 does not declare a `public struct Tomato`
2. `Caprese`, which declares a `public struct Tomato`
3. `MyApp`

Let's also assume that `MyApp` has both `import Caprese` and `import NIO` and it uses `Tomato` (from `Caprese`). For example `let t = Tomato()`.

If now in version `NIO` in version 2.1.0 introduces a `public struct Tomato { ... }` as well, then now compilation of `MyApp`'s compilation will fail will an ambiguity error.

With the guarantee that in minor versions NIO will only introduce `NIO`-prefixed types, this can not happen because NIO would call its type `NIOTomato` rather than `Tomato`.

C functions are all in a global namespace so even worse issues might hit you if NIO were to just introduce exported C functions with very general names in minor releases.

## What's the point of codifying all this?

We believe that it is important for the ecosystem that all parties can adopt each others' new versions quickly and easily. Therefore we always strongly recommend depending on all the projects in the NIO family which have a major version greater than or equal to 1 up to the next _major_ version. By following the guidelines set out above we should all not run into any trouble even when run with newer versions.

Example:

    .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),

Needless to say if you require at least version `2.3.4` you would specify `from: "2.3.4"`. The important part is that you use `from: "2.3.4"` or `.upToNextMajor(from: "2.3.4")` and not `.exact` or `.upToNextMinor`.

## What happens if you ignore these guidelines?

We are trying to be nice people and we ❤️ our users so we will never break anybody just because they didn't perfectly stick to these guidelines. But just ignoring those guidelines might mean rewriting some of your code, debugging random build, or runtime failures that we didn't hit in the pre-release testing. We do have a source compatibility suite to which you can [ask to be added](https://forums.swift.org/t/register-as-swiftnio-user-to-get-ahead-of-time-security-notifications-be-added-to-the-source-compatibility-suite/17792) and we try not to break you (within reason). But it is impossible for us to test all of our users' projects and we don't want to lose the ability to move fast without breaking things. Certain failures like clashing protocol conformances can have delicate failure modes.
