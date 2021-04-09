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

/// A configuration option that can be set on a `Channel` to configure different behaviour.
public protocol ChannelOption: Equatable {
    /// The type of the `ChannelOption`'s value.
    associatedtype Value
}

public typealias SocketOptionName = Int32
#if os(Linux) || os(Android)
    public typealias SocketOptionLevel = Int
    public typealias SocketOptionValue = Int
#else
    public typealias SocketOptionLevel = CInt
    public typealias SocketOptionValue = CInt
#endif

@available(*, deprecated, renamed: "ChannelOptions.Types.SocketOption")
public typealias SocketOption = ChannelOptions.Types.SocketOption

@available(*, deprecated, renamed: "ChannelOptions.Types.AllocatorOption")
public typealias AllocatorOption = ChannelOptions.Types.AllocatorOption

@available(*, deprecated, renamed: "ChannelOptions.Types.RecvAllocatorOption")
public typealias RecvAllocatorOption = ChannelOptions.Types.RecvAllocatorOption

@available(*, deprecated, renamed: "ChannelOptions.Types.AutoReadOption")
public typealias AutoReadOption = ChannelOptions.Types.AutoReadOption

@available(*, deprecated, renamed: "ChannelOptions.Types.WriteSpinOption")
public typealias WriteSpinOption = ChannelOptions.Types.WriteSpinOption

@available(*, deprecated, renamed: "ChannelOptions.Types.MaxMessagesPerReadOption")
public typealias MaxMessagesPerReadOption = ChannelOptions.Types.MaxMessagesPerReadOption

@available(*, deprecated, renamed: "ChannelOptions.Types.BacklogOption")
public typealias BacklogOption = ChannelOptions.Types.BacklogOption

@available(*, deprecated, renamed: "ChannelOptions.Types.DatagramVectorReadMessageCountOption")
public typealias DatagramVectorReadMessageCountOption = ChannelOptions.Types.DatagramVectorReadMessageCountOption

@available(*, deprecated, renamed: "ChannelOptions.Types.WriteBufferWaterMark")
public typealias WriteBufferWaterMark = ChannelOptions.Types.WriteBufferWaterMark

@available(*, deprecated, renamed: "ChannelOptions.Types.WriteBufferWaterMarkOption")
public typealias WriteBufferWaterMarkOption = ChannelOptions.Types.WriteBufferWaterMarkOption

@available(*, deprecated, renamed: "ChannelOptions.Types.ConnectTimeoutOption")
public typealias ConnectTimeoutOption = ChannelOptions.Types.ConnectTimeoutOption

@available(*, deprecated, renamed: "ChannelOptions.Types.AllowRemoteHalfClosureOption")
public typealias AllowRemoteHalfClosureOption = ChannelOptions.Types.AllowRemoteHalfClosureOption

extension ChannelOptions {
    public enum Types {

        /// `SocketOption` allows users to specify configuration settings that are directly applied to the underlying socket file descriptor.
        ///
        /// Valid options are typically found in the various man pages like `man 4 tcp`.
        public struct SocketOption: ChannelOption, Equatable {
            public typealias Value = (SocketOptionValue)

            public var optionLevel: NIOBSDSocket.OptionLevel
            public var optionName: NIOBSDSocket.Option

            public var level: SocketOptionLevel {
                get {
                    return SocketOptionLevel(optionLevel.rawValue)
                }
                set {
                    self.optionLevel = NIOBSDSocket.OptionLevel(rawValue: CInt(newValue))
                }
            }
            public var name: SocketOptionName {
                get {
                    return SocketOptionName(optionName.rawValue)
                }
                set {
                    self.optionName = NIOBSDSocket.Option(rawValue: CInt(newValue))
                }
            }

            #if !os(Windows)
                /// Create a new `SocketOption`.
                ///
                /// - parameters:
                ///     - level: The level for the option as defined in `man setsockopt`, e.g. SO_SOCKET.
                ///     - name: The name of the option as defined in `man setsockopt`, e.g. `SO_REUSEADDR`.
                public init(level: SocketOptionLevel, name: SocketOptionName) {
                    self.optionLevel = NIOBSDSocket.OptionLevel(rawValue: CInt(level))
                    self.optionName = NIOBSDSocket.Option(rawValue: CInt(name))
                }
            #endif

            /// Create a new `SocketOption`.
            ///
            /// - parameters:
            ///     - level: The level for the option as defined in `man setsockopt`, e.g. SO_SOCKET.
            ///     - name: The name of the option as defined in `man setsockopt`, e.g. `SO_REUSEADDR`.
            public init(level: NIOBSDSocket.OptionLevel, name: NIOBSDSocket.Option) {
                self.optionLevel = level
                self.optionName = name
            }
        }

        /// `AllocatorOption` allows to specify the `ByteBufferAllocator` to use.
        public struct AllocatorOption: ChannelOption {
            public typealias Value = ByteBufferAllocator

            public init() {}
        }

        /// `RecvAllocatorOption` allows users to specify the `RecvByteBufferAllocator` to use.
        public struct RecvAllocatorOption: ChannelOption {
            public typealias Value = RecvByteBufferAllocator

            public init() {}
        }

        /// `AutoReadOption` allows users to configure if a `Channel` should automatically call `Channel.read` again once all data was read from the transport or
        /// if the user is responsible to call `Channel.read` manually.
        public struct AutoReadOption: ChannelOption {
            public typealias Value = Bool

            public init() {}
        }

        /// `WriteSpinOption` allows users to configure the number of repetitions of a only partially successful write call before considering the `Channel` not writable.
        /// Setting this option to `0` means that we only issue one write call and if that call does not write all the bytes,
        /// we consider the `Channel` not writable.
        public struct WriteSpinOption: ChannelOption {
            public typealias Value = UInt

            public init() {}
        }

        /// `MaxMessagesPerReadOption` allows users to configure the maximum number of read calls to the underlying transport are performed before wait again until
        /// there is more to read and be notified.
        public struct MaxMessagesPerReadOption: ChannelOption {
            public typealias Value = UInt

            public init() {}
        }

        /// `BacklogOption` allows users to configure the `backlog` value as specified in `man 2 listen`. This is only useful for `ServerSocketChannel`s.
        public struct BacklogOption: ChannelOption {
            public typealias Value = Int32

            public init() {}
        }

        /// `DatagramVectorReadMessageCountOption` allows users to configure the number of messages to attempt to read in a single syscall on a
        /// datagram `Channel`.
        ///
        /// Some datagram `Channel`s have extremely high datagram throughput. This can occur when the single datagram socket is encapsulating
        /// many logical "connections" (e.g. with QUIC) or when the datagram socket is simply serving an enormous number of consumers (e.g.
        /// with a public-facing DNS server). In this case the overhead of one syscall per datagram is profoundly limiting. Using this
        /// `ChannelOption` allows the `Channel` to read multiple datagrams at once.
        ///
        /// Note that simply increasing this number will not necessarily bring performance gains and may in fact cause data loss. Any increase
        /// to this should be matched by increasing the size of the buffers allocated by the `Channel` `RecvByteBufferAllocator` (as set by
        /// `ChannelOption.recvAllocator`) proportionally. For example, to receive 10 messages at a time, set the size of the buffers allocated
        /// by the `RecvByteBufferAllocator` to at least 10x the size of the maximum datagram size you wish to receive.
        ///
        /// Naturally, this option is only valid on datagram channels.
        ///
        /// This option only works on the following platforms:
        ///
        /// - Linux
        /// - FreeBSD
        /// - Android
        ///
        /// On all other platforms, setting it has no effect.
        ///
        /// Set this option to 0 to disable vector reads and to use serial reads instead.
        public struct DatagramVectorReadMessageCountOption: ChannelOption {
            public typealias Value = Int

            public init() { }
        }
        
        /// When set to true IP level ECN information will be reported through `AddressedEnvelope.Metadata`
        public struct ExplicitCongestionNotificationsOption: ChannelOption {
            public typealias Value = Bool
            public init() {}
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

        /// `WriteBufferWaterMarkOption` allows users to configure when a `Channel` should be marked as writable or not. Once the amount of bytes queued in a
        /// `Channel`s outbound buffer is larger than `WriteBufferWaterMark.high` the channel will be marked as non-writable and so
        /// `Channel.isWritable` will return `false`. Once we were able to write some data out of the outbound buffer and the amount of bytes queued
        /// falls below `WriteBufferWaterMark.low` the `Channel` will become writable again. Once this happens `Channel.writable` will return
        /// `true` again. These writability changes are also propagated through the `ChannelPipeline` and so can be intercepted via `ChannelInboundHandler.channelWritabilityChanged`.
        public struct WriteBufferWaterMarkOption: ChannelOption {
            public typealias Value = WriteBufferWaterMark

            public init() {}
        }

        /// `ConnectTimeoutOption` allows users to configure the `TimeAmount` after which a connect will fail if it was not established in the meantime. May be
        /// `nil`, in which case the connection attempt will never time out.
        public struct ConnectTimeoutOption: ChannelOption {
            public typealias Value = TimeAmount?

            public init() {}
        }

        /// `AllowRemoteHalfClosureOption` allows users to configure whether the `Channel` will close itself when its remote
        /// peer shuts down its send stream, or whether it will remain open. If set to `false` (the default), the `Channel`
        /// will be closed automatically if the remote peer shuts down its send stream. If set to true, the `Channel` will
        /// not be closed: instead, a `ChannelEvent.inboundClosed` user event will be sent on the `ChannelPipeline`,
        /// and no more data will be received.
        public struct AllowRemoteHalfClosureOption: ChannelOption {
            public typealias Value = Bool

            public init() {}
        }
    }
}

/// Provides `ChannelOption`s to be used with a `Channel`, `Bootstrap` or `ServerBootstrap`.
public struct ChannelOptions {
    #if !os(Windows)
        public static let socket = { (level: SocketOptionLevel, name: SocketOptionName) -> Types.SocketOption in
            .init(level: NIOBSDSocket.OptionLevel(rawValue: CInt(level)), name: NIOBSDSocket.Option(rawValue: CInt(name)))
        }
    #endif

    /// - seealso: `SocketOption`.
    public static let socketOption = { (name: NIOBSDSocket.Option) -> Types.SocketOption in
        .init(level: .socket, name: name)
    }

    /// - seealso: `SocketOption`.
    public static let tcpOption = { (name: NIOBSDSocket.Option) -> Types.SocketOption in
        .init(level: .tcp, name: name)
    }

    /// - seealso: `AllocatorOption`.
    public static let allocator = Types.AllocatorOption()

    /// - seealso: `RecvAllocatorOption`.
    public static let recvAllocator = Types.RecvAllocatorOption()

    /// - seealso: `AutoReadOption`.
    public static let autoRead = Types.AutoReadOption()

    /// - seealso: `MaxMessagesPerReadOption`.
    public static let maxMessagesPerRead = Types.MaxMessagesPerReadOption()

    /// - seealso: `BacklogOption`.
    public static let backlog = Types.BacklogOption()

    /// - seealso: `WriteSpinOption`.
    public static let writeSpin = Types.WriteSpinOption()

    /// - seealso: `WriteBufferWaterMarkOption`.
    public static let writeBufferWaterMark = Types.WriteBufferWaterMarkOption()

    /// - seealso: `ConnectTimeoutOption`.
    public static let connectTimeout = Types.ConnectTimeoutOption()

    /// - seealso: `AllowRemoteHalfClosureOption`.
    public static let allowRemoteHalfClosure = Types.AllowRemoteHalfClosureOption()

    /// - seealso: `DatagramVectorReadMessageCountOption`
    public static let datagramVectorReadMessageCount = Types.DatagramVectorReadMessageCountOption()
    
    /// - seealso: `ExplicitCongestionNotificationsOption`
    public static let explicitCongestionNotification = Types.ExplicitCongestionNotificationsOption()
}

extension ChannelOptions {
    /// A type-safe storage facility for `ChannelOption`s. You will only ever need this if you implement your own
    /// `Channel` that needs to store `ChannelOption`s.
    public struct Storage {
        @usableFromInline
        internal var _storage: [(Any, (Any, (Channel) -> (Any, Any) -> EventLoopFuture<Void>))]

        public init() {
            self._storage = []
            self._storage.reserveCapacity(2)
        }

        /// Add `Options`, a `ChannelOption` to the `ChannelOptions.Storage`.
        ///
        /// - parameters:
        ///    - key: the key for the option
        ///    - value: the value for the option
        @inlinable
        public mutating func append<Option: ChannelOption>(key newKey: Option, value newValue: Option.Value) {
            func applier(_ t: Channel) -> (Any, Any) -> EventLoopFuture<Void> {
                return { (option, value) in
                    return t.setOption(option as! Option, value: value as! Option.Value)
                }
            }
            var hasSet = false
            self._storage = self._storage.map { currentKeyAndValue in
                let (currentKey, _) = currentKeyAndValue
                if let currentKey = currentKey as? Option, currentKey == newKey {
                    hasSet = true
                    return (currentKey, (newValue, applier))
                } else {
                    return currentKeyAndValue
                }
            }
            if !hasSet {
                self._storage.append((newKey, (newValue, applier)))
            }
        }

        /// Apply all stored `ChannelOption`s to `Channel`.
        ///
        /// - parameters:
        ///    - channel: The `Channel` to apply the `ChannelOption`s to
        /// - returns:
        ///    - An `EventLoopFuture` that is fulfilled when all `ChannelOption`s have been applied to the `Channel`.
        public func applyAllChannelOptions(to channel: Channel) -> EventLoopFuture<Void> {
            let applyPromise = channel.eventLoop.makePromise(of: Void.self)
            var it = self._storage.makeIterator()

            func applyNext() {
                guard let (key, (value, applier)) = it.next() else {
                    // If we reached the end, everything is applied.
                    applyPromise.succeed(())
                    return
                }

                applier(channel)(key, value).map {
                    applyNext()
                }.cascadeFailure(to: applyPromise)
            }
            applyNext()

            return applyPromise.futureResult
        }
    }
}
