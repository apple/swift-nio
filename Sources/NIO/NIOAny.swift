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
/// for the performance of a SwiftNIO application like `ByteBuffer`, `FileRegion` and `AddressEnvelope<ByteBuffer>` can be expected
/// to be wrapped almost without overhead. All others will have similar performance as if they were passed as an `Any` as
/// `NIOAny` just like `Any` will contain them within an existential container.
///
/// The most important use-cases for `NIOAny` are values travelling through the `ChannelPipeline` whose type can't
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
///         func channelRead(context: ChannelHandlerContext, data: NIOAny) {
///              /* we receive the `Bacon` as a `NIOAny` as at compile-time the exact configuration of the channel
///                 pipeline can't be computed. The pipeline can't be computed at compile time as it can change
///                 dynamically at run-time. Yet, we assert that in any configuration the channel handler before
///                 `SandwichHandler` does actually send us a stream of `Bacon`.
///              */
///              let bacon = self.unwrapInboundIn(data) /* `Bacon` or crash */
///              let sandwich = makeSandwich(bacon)
///              context.fireChannelRead(self.wrapInboundOut(sandwich)) /* as promised we deliver a wrapped `Sandwich` */
///         }
///     }
public struct NIOAny {
    @usableFromInline
    /* private but _versioned */ let _storage: _NIOAny

    /// Wrap a value in a `NIOAny`. In most cases you should not create a `NIOAny` directly using this constructor.
    /// The abstraction that accepts values of type `NIOAny` must also provide a mechanism to do the wrapping. An
    /// example is a `ChannelInboundHandler` which provides `self.wrapInboundOut(aValueOfTypeInboundOut)`.
    @inlinable
    public init<T>(_ value: T) {
        self._storage = _NIOAny(value)
    }

    @usableFromInline
    enum _NIOAny {
        case ioData(IOData)
        case bufferEnvelope(AddressedEnvelope<ByteBuffer>)
        case other(Any)

        @inlinable
        init<T>(_ value: T) {
            switch value {
            case let value as ByteBuffer:
                self = .ioData(.byteBuffer(value))
            case let value as FileRegion:
                self = .ioData(.fileRegion(value))
            case let value as IOData:
                self = .ioData(value)
            case let value as AddressedEnvelope<ByteBuffer>:
                self = .bufferEnvelope(value)
            default:
                assert(!(value is NIOAny))
                self = .other(value)
            }
        }
    }

    /// Try unwrapping the wrapped message as `ByteBuffer`.
    ///
    /// returns: The wrapped `ByteBuffer` or `nil` if the wrapped message is not a `ByteBuffer`.
    @inlinable
    func tryAsByteBuffer() -> ByteBuffer? {
        if case .ioData(.byteBuffer(let bb)) = self._storage {
            return bb
        } else {
            return nil
        }
    }

    /// Force unwrapping the wrapped message as `ByteBuffer`.
    ///
    /// returns: The wrapped `ByteBuffer` or crash if the wrapped message is not a `ByteBuffer`.
    @inlinable
    func forceAsByteBuffer() -> ByteBuffer {
        if let v = tryAsByteBuffer() {
            return v
        } else {
            fatalError("tried to decode as type \(ByteBuffer.self) but found \(Mirror(reflecting: Mirror(reflecting: self._storage).children.first!.value).subjectType) with contents \(self._storage)")
        }
    }

    /// Try unwrapping the wrapped message as `IOData`.
    ///
    /// returns: The wrapped `IOData` or `nil` if the wrapped message is not a `IOData`.
    @inlinable
    func tryAsIOData() -> IOData? {
        if case .ioData(let data) = self._storage {
            return data
        } else {
            return nil
        }
    }

    /// Force unwrapping the wrapped message as `IOData`.
    ///
    /// returns: The wrapped `IOData` or crash if the wrapped message is not a `IOData`.
    @inlinable
    func forceAsIOData() -> IOData {
        if let v = tryAsIOData() {
            return v
        } else {
            fatalError("tried to decode as type \(IOData.self) but found \(Mirror(reflecting: Mirror(reflecting: self._storage).children.first!.value).subjectType) with contents \(self._storage)")
        }
    }

    /// Try unwrapping the wrapped message as `FileRegion`.
    ///
    /// returns: The wrapped `FileRegion` or `nil` if the wrapped message is not a `FileRegion`.
    @inlinable
    func tryAsFileRegion() -> FileRegion? {
        if case .ioData(.fileRegion(let f)) = self._storage {
            return f
        } else {
            return nil
        }
    }

    /// Force unwrapping the wrapped message as `FileRegion`.
    ///
    /// returns: The wrapped `FileRegion` or crash if the wrapped message is not a `FileRegion`.
    @inlinable
    func forceAsFileRegion() -> FileRegion {
        if let v = tryAsFileRegion() {
            return v
        } else {
            fatalError("tried to decode as type \(FileRegion.self) but found \(Mirror(reflecting: Mirror(reflecting: self._storage).children.first!.value).subjectType) with contents \(self._storage)")
        }
    }

    /// Try unwrapping the wrapped message as `AddressedEnvelope<ByteBuffer>`.
    ///
    /// returns: The wrapped `AddressedEnvelope<ByteBuffer>` or `nil` if the wrapped message is not an `AddressedEnvelope<ByteBuffer>`.
    @inlinable
    func tryAsByteEnvelope() -> AddressedEnvelope<ByteBuffer>? {
        if case .bufferEnvelope(let e) = self._storage {
            return e
        } else {
            return nil
        }
    }

    /// Force unwrapping the wrapped message as `AddressedEnvelope<ByteBuffer>`.
    ///
    /// returns: The wrapped `AddressedEnvelope<ByteBuffer>` or crash if the wrapped message is not an `AddressedEnvelope<ByteBuffer>`.
    @inlinable
    func forceAsByteEnvelope() -> AddressedEnvelope<ByteBuffer> {
        if let e = tryAsByteEnvelope() {
            return e
        } else {
            fatalError("tried to decode as type \(AddressedEnvelope<ByteBuffer>.self) but found \(Mirror(reflecting: Mirror(reflecting: self._storage).children.first!.value).subjectType) with contents \(self._storage)")
        }
    }

    /// Try unwrapping the wrapped message as `T`.
    ///
    /// returns: The wrapped `T` or `nil` if the wrapped message is not a `T`.
    @inlinable
    func tryAsOther<T>(type: T.Type = T.self) -> T? {
        switch self._storage {
        case .bufferEnvelope(let v):
            return v as? T
        case .ioData(let v):
            return v as? T
        case .other(let v):
            return v as? T
        }
    }

    /// Force unwrapping the wrapped message as `T`.
    ///
    /// returns: The wrapped `T` or crash if the wrapped message is not a `T`.
    @inlinable
    func forceAsOther<T>(type: T.Type = T.self) -> T {
        if let v = tryAsOther(type: type) {
            return v
        } else {
            fatalError("tried to decode as type \(T.self) but found \(Mirror(reflecting: Mirror(reflecting: self._storage).children.first!.value).subjectType) with contents \(self._storage)")
        }
    }

    /// Force unwrapping the wrapped message as `T`.
    ///
    /// returns: The wrapped `T` or crash if the wrapped message is not a `T`.
    @inlinable
    func forceAs<T>(type: T.Type = T.self) -> T {
        switch T.self {
        case let t where t == ByteBuffer.self:
            return self.forceAsByteBuffer() as! T
        case let t where t == FileRegion.self:
            return self.forceAsFileRegion() as! T
        case let t where t == IOData.self:
            return self.forceAsIOData() as! T
        case let t where t == AddressedEnvelope<ByteBuffer>.self:
            return self.forceAsByteEnvelope() as! T
        default:
            return self.forceAsOther(type: type)
        }
    }

    /// Try unwrapping the wrapped message as `T`.
    ///
    /// returns: The wrapped `T` or `nil` if the wrapped message is not a `T`.
    @inlinable
    func tryAs<T>(type: T.Type = T.self) -> T? {
        switch T.self {
        case let t where t == ByteBuffer.self:
            return self.tryAsByteBuffer() as! T?
        case let t where t == FileRegion.self:
            return self.tryAsFileRegion() as! T?
        case let t where t == IOData.self:
            return self.tryAsIOData() as! T?
        case let t where t == AddressedEnvelope<ByteBuffer>.self:
            return self.tryAsByteEnvelope() as! T?
        default:
            return self.tryAsOther(type: type)
        }
    }

    /// Unwrap the wrapped message.
    ///
    /// returns: The wrapped message.
    @inlinable
    func asAny() -> Any {
        switch self._storage {
        case .ioData(.byteBuffer(let bb)):
            return bb
        case .ioData(.fileRegion(let f)):
            return f
        case .bufferEnvelope(let e):
            return e
        case .other(let o):
            return o
        }
    }
}

extension NIOAny: CustomStringConvertible {
    public var description: String {
        return "NIOAny { \(self.asAny()) }"
    }
}
