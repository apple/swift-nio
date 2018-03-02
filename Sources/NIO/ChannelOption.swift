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

/// An configuration option that can be set on a `Channel` to configure different behaviour.
public protocol ChannelOption {
    associatedtype AssociatedValueType
    associatedtype OptionType

    /// The value of the `ChannelOption`.
    var value: AssociatedValueType { get }

    /// The type of the `ChannelOption`
    var type: OptionType.Type { get }
}

extension ChannelOption {
    public var type: OptionType.Type {
        return OptionType.self
    }
}

extension ChannelOption where AssociatedValueType == () {
    public var value: () {
        return ()
    }
}

public typealias SocketOptionName = Int32
#if os(Linux)
    public typealias SocketOptionLevel = Int
    public typealias SocketOptionValue = Int
#else
    public typealias SocketOptionLevel = Int32
    public typealias SocketOptionValue = Int32
#endif

/// `SocketOption` allows to specify configuration settings that are directly applied to the underlying socket file descriptor.
///
/// Valid options are typically found in the various man pages like `man 4 tcp`.
public enum SocketOption: ChannelOption {
    public typealias AssociatedValueType = (SocketOptionLevel, SocketOptionName)

    public typealias OptionType = (SocketOptionValue)

    case const(AssociatedValueType)

    /// Create a new `SocketOption`.
    ///
    /// - parameters:
    ///       - level: The level for the option as defined in `man setsockopt`, e.g. SO_SOCKET.
    ///       - name: The name of the option as defined in `man setsockopt`, e.g. `SO_REUSEADDR`.
    public init(level: SocketOptionLevel, name: SocketOptionName) {
        self = .const((level, name))
    }

    public var value: (SocketOptionLevel, SocketOptionName) {
        switch self {
        case .const(let level, let name):
            return (level, name)
        }
    }
}

/// `AllocatorOption` allows to specify the `ByteBufferAllocator` to use.
public enum AllocatorOption: ChannelOption {
    public typealias AssociatedValueType = ()
    public typealias OptionType = ByteBufferAllocator

    case const(())
}

/// `RecvAllocatorOption` allows to specify the `RecvByteBufferAllocator` to use.
public enum RecvAllocatorOption: ChannelOption {
    public typealias AssociatedValueType = ()
    public typealias OptionType = RecvByteBufferAllocator

    case const(())
}

/// `AutoReadOption` allows to configure if a `Channel` should automatically call `Channel.read` again once all data was read from the transport or
/// if the user is responsible to call `Channel.read` manually.
public enum AutoReadOption: ChannelOption {
    public typealias AssociatedValueType = ()
    public typealias OptionType = Bool

    case const(())
}

/// `WriteSpinOption` allows users to configure the number of repetitions of a only partially successful write call before considering the `Channel` not writable.
/// Setting this option to `0` means that we only issue one write call and if that call does not write all the bytes,
/// we consider the `Channel` not writable.
public enum WriteSpinOption: ChannelOption {
    public typealias AssociatedValueType = ()
    public typealias OptionType = UInt

    case const(())
}

/// `MaxMessagesPerReadOption` allows to configure the maximum number of read calls to the underlying transport are performed before wait again until
/// there is more to read and be notified.
public enum MaxMessagesPerReadOption: ChannelOption {
    public typealias AssociatedValueType = ()
    public typealias OptionType = UInt

    case const(())
}

/// `BacklogOption` allows to configure the `backlog` value as specified in `man 2 listen`. This is only useful for `ServerSocketChannel`s.
public enum BacklogOption: ChannelOption {
    public typealias AssociatedValueType = ()
    public typealias OptionType = Int32

    case const(())
}

/// The watermark used to detect when `Channel.isWritable` returns `true` or `false`.
public struct WriteBufferWaterMark {
    /// The low mark setting for a `Channel`.
    ///
    /// When the amount of buffered bytes in the `Channel`s outbound buffer drops below this value the `Channel` will be
    /// marked as writable again (after it was non-writable).
    public let low: Int

    /// The high mark setting for a `Channel`.
    ///
    /// When the amount of buffered bytes in the `Channel`s outbound exceeds this value the `Channel` will be
    /// marked as non-writable. It will be marked as writable again once the amount of buffered bytes drops below `low`.
    public let high: Int

    /// Create a new instance.
    ///
    /// Valid initialization is restricted to `1 <= low <= high`.
    ///
    /// - parameters:
    ///      - low: The low watermark.
    ///      - high: The high watermark.
    public init(low: Int, high: Int) {
        precondition(low >= 1, "low must be >= 1 but was \(low)")
        precondition(high >= low, "low must be <= high, but was low: \(low) high: \(high)")
        self.low = low
        self.high = high
    }
}

/// `WriteBufferWaterMarkOption` allows to configure when a `Channel` should be marked as writable or not. Once the amount of bytes queued in a
/// `Channel`s outbound buffer is larger than `WriteBufferWaterMark.high` the channel will be marked as non-writable and so
/// `Channel.isWritable` will return `false`. Once we were able to write some data out of the outbound buffer and the amount of bytes queued
/// falls below `WriteBufferWaterMark.low` the `Channel` will become writable again. Once this happens `Channel.writable` will return
/// `true` again. These writability changes are also propagated through the `ChannelPipeline` and so can be intercepted via `ChannelInboundHandler.channelWritabilityChanged`.
public enum WriteBufferWaterMarkOption: ChannelOption {
    public typealias AssociatedValueType = ()
    public typealias OptionType = WriteBufferWaterMark

    case const(())
}

/// `ConnectTimeoutOption` allows to configure the `TimeAmount` after which a connect will fail if it was not established in the meantime. May be
/// `nil`, in which case the connection attempt will never time out.
public enum ConnectTimeoutOption: ChannelOption {
    public typealias AssociatedValueType = ()
    public typealias OptionType = TimeAmount?

    case const(())
}

/// `AllowRemoteHalfClosureOption` allows users to configure whether the `Channel` will close itself when its remote
/// peer shuts down its send stream, or whether it will remain open. If set to `false` (the default), the `Channel`
/// will be closed automatically if the remote peer shuts down its send stream. If set to true, the `Channel` will
/// not be closed: instead, a `ChannelEvent.inboundClosed` user event will be sent on the `ChannelPipeline`,
/// and no more data will be received.
public enum AllowRemoteHalfClosureOption: ChannelOption {
    public typealias AssociatedValueType = ()
    public typealias OptionType = Bool

    case const(())
}

/// Provides `ChannelOption`s to be used with a `Channel`, `Bootstrap` or `ServerBootstrap`.
public struct ChannelOptions {
    /// - seealso: `SocketOption`.
    public static let socket = { (level: SocketOptionLevel, name: SocketOptionName) -> SocketOption in .const((level, name)) }

    /// - seealso: `AllocatorOption`.
    public static let allocator = AllocatorOption.const(())

    /// - seealso: `RecvAllocatorOption`.
    public static let recvAllocator = RecvAllocatorOption.const(())

    /// - seealso: `AutoReadOption`.
    public static let autoRead = AutoReadOption.const(())

    /// - seealso: `MaxMessagesPerReadOption`.
    public static let maxMessagesPerRead = MaxMessagesPerReadOption.const(())

    /// - seealso: `BacklogOption`.
    public static let backlog = BacklogOption.const(())

    /// - seealso: `WriteSpinOption`.
    public static let writeSpin = WriteSpinOption.const(())

    /// - seealso: `WriteBufferWaterMarkOption`.
    public static let writeBufferWaterMark = WriteBufferWaterMarkOption.const(())

    /// - seealso: `ConnectTimeoutOption`.
    public static let connectTimeout = ConnectTimeoutOption.const(())

    /// - seealso: `AllowRemoteHalfClosureOption`.
    public static let allowRemoteHalfClosure = AllowRemoteHalfClosureOption.const(())
}
