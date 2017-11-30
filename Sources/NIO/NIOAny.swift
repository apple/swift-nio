//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// `NIOAny` is an opaque container for values of *any* type, similar to Swift's builtin `Any` type. Contrary to
/// `Any` the overhead of `NIOAny` depends on the the type of the wrapped value. Certain types that are important
/// for the performance of a SwiftNIO appliation like `ByteBuffer` and `FileRegion` can be expected to be wrapped almost
/// without overhead. All others will have similar performance as if they were passed as an `Any` as `NIOAny` just
/// like `Any` will contain them within an existential container.
///
/// The most important use-cases for `NIOAny` are values travelling through the channel pipeline whose type can't
/// be calculated at compile time. For example:
///
///  - the `channelRead` of any `ChannelInboundHandler`
///  - the `write` method of a `ChannelOutboundHandler`
///
/// The abstraction that delivers a `NIOAny` to user code must provide a mechanism to unwrap a `NIOAny` as a
/// certain type known at run-time. Canonical example:
///
///     class SandwichHandler: ChannelInboundHandler {
///         typealias InboundIn = Bacon /* we expected to be delivered `Bacon` ... */
///         typealias InboundOut = Sandwich /* ... and we will make and deliver a `Sandwich` from that */
///
///         func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
///              /* we receive the `Bacon` as a `NIOAny` as at compile-time the exact configuration of the channel
///                 pipeline can't be computed. The pipeline can't be computed at compile time as it can change
///                 dynamically at run-time. Yet, we assert that in any configuration the channel handler before
///                 `SandwichHandler` does actually send us a stream of `Bacon`.
///              */
///              let bacon = self.unwrapInboundIn(data) /* `Bacon` or crash */
///              let sandwich = makeSandwich(bacon)
///              ctx.fireChannelRead(data: self.wrapInboundOut(sandwich)) /* as promised we deliver a wrapped `Sandwich` */
///         }
///     }
public struct NIOAny {
    private let storage: _NIOAny

    /// Wrap a value in a `NIOAny`. In most cases you should not create a `NIOAny` directly using this constructor.
    /// The abstraction that accepts values of type `NIOAny` must also provide a mechanism to do the wrapping. An
    /// example is a `ChannelInboundHandler` which provides `self.wrapInboundOut(aValueOfTypeInboundOut)`.
    public init<T>(_ value: T) {
        self.storage = _NIOAny(value)
    }
    
    enum _NIOAny {
        case ioData(IOData)
        case other(Any)
        
        init<T>(_ value: T) {
            switch value {
            case let value as ByteBuffer:
                self = .ioData(.byteBuffer(value))
            case let value as FileRegion:
                self = .ioData(.fileRegion(value))
            case let value as IOData:
                self = .ioData(value)
            default:
                self = .other(value)
            }
        }
        
    }
    
    func tryAsByteBuffer() -> ByteBuffer? {
        if case .ioData(.byteBuffer(let bb)) = self.storage {
            return bb
        } else {
            return nil
        }
    }
    
    func forceAsByteBuffer() -> ByteBuffer {
        if let v = tryAsByteBuffer() {
            return v
        } else {
            fatalError("tried to decode as type \(ByteBuffer.self) but found \(Mirror(reflecting: Mirror(reflecting: self.storage).children.first!.value).subjectType)")
        }
    }
    
    func tryAsIOData() -> IOData? {
        if case .ioData(let data) = self.storage {
            return data
        } else {
            return nil
        }
    }
    
    func forceAsIOData() -> IOData {
        if let v = tryAsIOData() {
            return v
        } else {
            fatalError("tried to decode as type \(IOData.self) but found \(Mirror(reflecting: Mirror(reflecting: self.storage).children.first!.value).subjectType)")
        }
    }
    
    func tryAsFileRegion() -> FileRegion? {
        if case .ioData(.fileRegion(let f)) = self.storage {
            return f
        } else {
            return nil
        }
    }
    
    func forceAsFileRegion() -> FileRegion {
        if let v = tryAsFileRegion() {
            return v
        } else {
            fatalError("tried to decode as type \(FileRegion.self) but found \(Mirror(reflecting: Mirror(reflecting: self.storage).children.first!.value).subjectType)")
        }
    }
    
    func tryAsOther<T>(type: T.Type = T.self) -> T? {
        if case .other(let any) = self.storage {
            return any as? T
        } else {
            return nil
        }
    }
    
    func forceAsOther<T>(type: T.Type = T.self) -> T {
        if let v = tryAsOther(type: type) {
            return v
        } else {
            fatalError("tried to decode as type \(T.self) but found \(Mirror(reflecting: Mirror(reflecting: self.storage).children.first!.value).subjectType)")
        }
    }
    
    func forceAs<T>(type: T.Type = T.self) -> T {
        if T.self == ByteBuffer.self {
            return self.forceAsByteBuffer() as! T
        } else if T.self == FileRegion.self {
            return self.forceAsFileRegion() as! T
        } else if T.self == IOData.self {
            return self.forceAsIOData() as! T
        } else {
            return self.forceAsOther(type: type)
        }
    }
    
    func tryAs<T>(type: T.Type = T.self) -> T? {
        if T.self == ByteBuffer.self {
            return self.tryAsByteBuffer() as! T?
        } else if T.self == FileRegion.self {
            return self.tryAsFileRegion() as! T?
        } else if T.self == IOData.self {
            return self.tryAsIOData() as! T?
        } else {
            return self.tryAsOther(type: type)
        }
    }
    
    func asAny() -> Any {
        switch self.storage {
        case .ioData(.byteBuffer(let bb)):
            return bb
        case .ioData(.fileRegion(let f)):
            return f
        case .other(let o):
            return o
        }
    }
}
