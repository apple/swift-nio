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

/// `WriteSpinOption` allows to configure the number of write calls to do before consider the `Channel` as non-writable and give up until it
/// becomes writable again.
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

/// The watermark used to detect once `Channel.writable` returns `true` or `false`.
public typealias WriteBufferWaterMark = Range<Int>

/// `WriteBufferWaterMarkOption` allows to configure when a `Channel` should be marked as writable or not. Once the amount of bytes queued in a
/// `Channel`s outbound buffer is larger then the upper value of the `WriteBufferWaterMark` the channel will be marked as non-writable and so
/// `Channel.isWritable` will return `false`. Once we were able to write some data out of the outbound buffer and the amount of bytes queued
/// falls under the lower value of `WriteBufferWaterMark` the `Channel` will become writable again. Once this happens  `Channel.writable` will return
/// `true` again. These writability changes are also propagated through the `ChannelPipeline` via the `ChannelPipeline.fireChannelWritabilityChanged`
/// method and so its possible to act on this in a `ChannelInboundHandler` implementation.
public enum WriteBufferWaterMarkOption: ChannelOption {
    public typealias AssociatedValueType = ()
    public typealias OptionType = WriteBufferWaterMark
    
    case const(())
}

/// `ConnectTimeoutOption` allows to configure the `TimeAmount` after which a connect will fail if it was not established in the meantime.
public enum ConnectTimeoutOption: ChannelOption {
    public typealias AssociatedValueType = ()
    public typealias OptionType = TimeAmount
    
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
