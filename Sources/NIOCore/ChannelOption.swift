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
public protocol ChannelOption: Equatable, _NIOPreconcurrencySendable {
    /// The type of the `ChannelOption`'s value.
    associatedtype Value: Sendable
}

public typealias SocketOptionName = Int32
#if (os(Linux) || os(Android)) && !canImport(Musl)
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
    public enum Types: Sendable {

        /// `SocketOption` allows users to specify configuration settings that are directly applied to the underlying socket file descriptor.
        ///
        /// Valid options are typically found in the various man pages like `man 4 tcp`.
        public struct SocketOption: ChannelOption, Equatable, Sendable {
            public typealias Value = (SocketOptionValue)

            public var optionLevel: NIOBSDSocket.OptionLevel
            public var optionName: NIOBSDSocket.Option

            public var level: SocketOptionLevel {
                get {
                    SocketOptionLevel(optionLevel.rawValue)
                }
                set {
                    self.optionLevel = NIOBSDSocket.OptionLevel(rawValue: CInt(newValue))
                }
            }
            public var name: SocketOptionName {
                get {
                    SocketOptionName(optionName.rawValue)
                }
                set {
                    self.optionName = NIOBSDSocket.Option(rawValue: CInt(newValue))
                }
            }

            #if !os(Windows)
            /// Create a new `SocketOption`.
            ///
            /// - Parameters:
            ///   - level: The level for the option as defined in `man setsockopt`, e.g. SO_SOCKET.
            ///   - name: The name of the option as defined in `man setsockopt`, e.g. `SO_REUSEADDR`.
            public init(level: SocketOptionLevel, name: SocketOptionName) {
                self.optionLevel = NIOBSDSocket.OptionLevel(rawValue: CInt(level))
                self.optionName = NIOBSDSocket.Option(rawValue: CInt(name))
            }
            #endif

            /// Create a new `SocketOption`.
            ///
            /// - Parameters:
            ///   - level: The level for the option as defined in `man setsockopt`, e.g. SO_SOCKET.
            ///   - name: The name of the option as defined in `man setsockopt`, e.g. `SO_REUSEADDR`.
            public init(level: NIOBSDSocket.OptionLevel, name: NIOBSDSocket.Option) {
                self.optionLevel = level
                self.optionName = name
            }
        }

        /// `AllocatorOption` allows to specify the `ByteBufferAllocator` to use.
        public struct AllocatorOption: ChannelOption, Sendable {
            public typealias Value = ByteBufferAllocator

            public init() {}
        }

        /// `RecvAllocatorOption` allows users to specify the `RecvByteBufferAllocator` to use.
        public struct RecvAllocatorOption: ChannelOption, Sendable {
            public typealias Value = RecvByteBufferAllocator

            public init() {}
        }

        /// `AutoReadOption` allows users to configure if a `Channel` should automatically call `Channel.read` again once all data was read from the transport or
        /// if the user is responsible to call `Channel.read` manually.
        public struct AutoReadOption: ChannelOption, Sendable {
            public typealias Value = Bool

            public init() {}
        }

        /// `WriteSpinOption` allows users to configure the number of repetitions of a only partially successful write call before considering the `Channel` not writable.
        /// Setting this option to `0` means that we only issue one write call and if that call does not write all the bytes,
        /// we consider the `Channel` not writable.
        public struct WriteSpinOption: ChannelOption, Sendable {
            public typealias Value = UInt

            public init() {}
        }

        /// `MaxMessagesPerReadOption` allows users to configure the maximum number of read calls to the underlying transport are performed before wait again until
        /// there is more to read and be notified.
        public struct MaxMessagesPerReadOption: ChannelOption, Sendable {
            public typealias Value = UInt

            public init() {}
        }

        /// `BacklogOption` allows users to configure the `backlog` value as specified in `man 2 listen`. This is only useful for `ServerSocketChannel`s.
        public struct BacklogOption: ChannelOption, Sendable {
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
        public struct DatagramVectorReadMessageCountOption: ChannelOption, Sendable {
            public typealias Value = Int

            public init() {}
        }

        /// ``DatagramSegmentSize`` controls the `UDP_SEGMENT` socket option (sometimes reffered to as 'GSO') which allows for
        /// large writes to be sent via `sendmsg` and `sendmmsg` and segmented into separate datagrams by the kernel (or in some cases, the NIC).
        /// The size of segments the large write is split into is controlled by the value of this option (note that writes do not need to be a
        /// multiple of this option).
        ///
        /// This option is currently only supported on Linux (4.18 and newer). Support can be checked using ``System/supportsUDPSegmentationOffload``.
        ///
        /// Setting this option to zero disables segmentation offload.
        public struct DatagramSegmentSize: ChannelOption, Sendable {
            public typealias Value = CInt
            public init() {}
        }

        /// ``DatagramReceiveOffload`` sets the `UDP_GRO` socket option which allows for datagrams to be accumulated
        /// by the kernel (or in some cases, the NIC) and reduces traversals in the kernel's networking layer.
        ///
        /// This option is currently only supported on Linux (5.10 and newer). Support can be checked
        /// using ``System/supportsUDPReceiveOffload``.
        ///
        /// - Note: users should ensure they use an appropriate receive buffer allocator when enabling this option.
        ///   The default allocator for datagram channels uses fixed sized buffers of 2048 bytes.
        public struct DatagramReceiveOffload: ChannelOption, Sendable {
            public typealias Value = Bool
            public init() {}
        }

        /// ``DatagramReceiveSegmentSize`` enables per-message GRO (Generic Receive Offload) segment size reporting.
        /// When enabled, the kernel will provide the original segment size via control messages for aggregated datagrams,
        /// which will be reported in `AddressedEnvelope.Metadata.segmentSize`.
        ///
        /// This option requires ``DatagramReceiveOffload`` to be enabled first and is only supported on Linux.
        /// Support can be checked using ``System/supportsUDPReceiveOffload``.
        ///
        /// - Note: This provides the receive-side complement to per-message GSO (``AddressedEnvelope/Metadata/segmentSize``).
        public struct DatagramReceiveSegmentSize: ChannelOption, Sendable {
            public typealias Value = Bool
            public init() {}
        }

        /// When set to true IP level ECN information will be reported through `AddressedEnvelope.Metadata`
        public struct ExplicitCongestionNotificationsOption: ChannelOption, Sendable {
            public typealias Value = Bool
            public init() {}
        }

        /// The watermark used to detect when `Channel.isWritable` returns `true` or `false`.
        public struct WriteBufferWaterMark: Sendable {
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
            /// - Parameters:
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
        public struct WriteBufferWaterMarkOption: ChannelOption, Sendable {
            public typealias Value = WriteBufferWaterMark

            public init() {}
        }

        /// `ConnectTimeoutOption` allows users to configure the `TimeAmount` after which a connect will fail if it was not established in the meantime. May be
        /// `nil`, in which case the connection attempt will never time out.
        public struct ConnectTimeoutOption: ChannelOption, Sendable {
            public typealias Value = TimeAmount?

            public init() {}
        }

        /// `AllowRemoteHalfClosureOption` allows users to configure whether the `Channel` will close itself when its remote
        /// peer shuts down its send stream, or whether it will remain open. If set to `false` (the default), the `Channel`
        /// will be closed automatically if the remote peer shuts down its send stream. If set to true, the `Channel` will
        /// not be closed: instead, a `ChannelEvent.inboundClosed` user event will be sent on the `ChannelPipeline`,
        /// and no more data will be received.
        public struct AllowRemoteHalfClosureOption: ChannelOption, Sendable {
            public typealias Value = Bool

            public init() {}
        }

        /// When set to true IP level Packet Info information will be reported through `AddressedEnvelope.Metadata` for UDP packets.
        public struct ReceivePacketInfo: ChannelOption, Sendable {
            public typealias Value = Bool
            public init() {}
        }

        /// `BufferedWritableBytesOption` allows users to know the number of writable bytes currently buffered in the `Channel`.
        public struct BufferedWritableBytesOption: ChannelOption, Sendable {
            public typealias Value = Int

            public init() {}
        }
    }
}

/// Provides `ChannelOption`s to be used with a `Channel`, `Bootstrap` or `ServerBootstrap`.
public struct ChannelOptions: Sendable {
    #if !os(Windows)
    public static let socket: @Sendable (SocketOptionLevel, SocketOptionName) -> ChannelOptions.Types.SocketOption = {
        (level: SocketOptionLevel, name: SocketOptionName) -> Types.SocketOption in
        .init(level: NIOBSDSocket.OptionLevel(rawValue: CInt(level)), name: NIOBSDSocket.Option(rawValue: CInt(name)))
    }
    #endif

    /// - seealso: `SocketOption`.
    public static let socketOption: @Sendable (NIOBSDSocket.Option) -> ChannelOptions.Types.SocketOption = {
        (name: NIOBSDSocket.Option) -> Types.SocketOption in
        .init(level: .socket, name: name)
    }

    /// - seealso: `SocketOption`.
    public static let ipOption: @Sendable (NIOBSDSocket.Option) -> ChannelOptions.Types.SocketOption = {
        (name: NIOBSDSocket.Option) -> Types.SocketOption in
        .init(level: .ip, name: name)
    }

    /// - seealso: `SocketOption`.
    public static let tcpOption: @Sendable (NIOBSDSocket.Option) -> ChannelOptions.Types.SocketOption = {
        (name: NIOBSDSocket.Option) -> Types.SocketOption in
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

    /// - seealso: `DatagramSegmentSize`
    public static let datagramSegmentSize = Types.DatagramSegmentSize()

    /// - seealso: `DatagramReceiveOffload`
    public static let datagramReceiveOffload = Types.DatagramReceiveOffload()

    /// - seealso: `DatagramReceiveSegmentSize`
    public static let datagramReceiveSegmentSize = Types.DatagramReceiveSegmentSize()

    /// - seealso: `ExplicitCongestionNotificationsOption`
    public static let explicitCongestionNotification = Types.ExplicitCongestionNotificationsOption()

    /// - seealso: `ReceivePacketInfo`
    public static let receivePacketInfo = Types.ReceivePacketInfo()

    /// - seealso: `BufferedWritableBytesOption`
    public static let bufferedWritableBytes = Types.BufferedWritableBytesOption()
}

/// - seealso: `SocketOption`.
extension ChannelOption where Self == ChannelOptions.Types.SocketOption {
    #if !(os(Windows))
    public static func socket(_ level: SocketOptionLevel, _ name: SocketOptionName) -> Self {
        .init(level: NIOBSDSocket.OptionLevel(rawValue: CInt(level)), name: NIOBSDSocket.Option(rawValue: CInt(name)))
    }
    #endif

    public static func socketOption(_ name: NIOBSDSocket.Option) -> Self {
        .init(level: .socket, name: name)
    }

    public static func ipOption(_ name: NIOBSDSocket.Option) -> Self {
        .init(level: .ip, name: name)
    }

    public static func tcpOption(_ name: NIOBSDSocket.Option) -> Self {
        .init(level: .tcp, name: name)
    }
}

/// - seealso: `AllocatorOption`.
extension ChannelOption where Self == ChannelOptions.Types.AllocatorOption {
    public static var allocator: Self { .init() }
}

/// - seealso: `RecvAllocatorOption`.
extension ChannelOption where Self == ChannelOptions.Types.RecvAllocatorOption {
    public static var recvAllocator: Self { .init() }
}

/// - seealso: `AutoReadOption`.
extension ChannelOption where Self == ChannelOptions.Types.AutoReadOption {
    public static var autoRead: Self { .init() }
}

/// - seealso: `MaxMessagesPerReadOption`.
extension ChannelOption where Self == ChannelOptions.Types.MaxMessagesPerReadOption {
    public static var maxMessagesPerRead: Self { .init() }
}

/// - seealso: `BacklogOption`.
extension ChannelOption where Self == ChannelOptions.Types.BacklogOption {
    public static var backlog: Self { .init() }
}

/// - seealso: `WriteSpinOption`.
extension ChannelOption where Self == ChannelOptions.Types.WriteSpinOption {
    public static var writeSpin: Self { .init() }
}

/// - seealso: `WriteBufferWaterMarkOption`.
extension ChannelOption where Self == ChannelOptions.Types.WriteBufferWaterMarkOption {
    public static var writeBufferWaterMark: Self { .init() }
}

/// - seealso: `ConnectTimeoutOption`.
extension ChannelOption where Self == ChannelOptions.Types.ConnectTimeoutOption {
    public static var connectTimeout: Self { .init() }
}

/// - seealso: `AllowRemoteHalfClosureOption`.
extension ChannelOption where Self == ChannelOptions.Types.AllowRemoteHalfClosureOption {
    public static var allowRemoteHalfClosure: Self { .init() }
}

/// - seealso: `DatagramVectorReadMessageCountOption`.
extension ChannelOption where Self == ChannelOptions.Types.DatagramVectorReadMessageCountOption {
    public static var datagramVectorReadMessageCount: Self { .init() }
}

/// - seealso: `DatagramSegmentSize`.
extension ChannelOption where Self == ChannelOptions.Types.DatagramSegmentSize {
    public static var datagramSegmentSize: Self { .init() }
}

/// - seealso: `DatagramReceiveOffload`.
extension ChannelOption where Self == ChannelOptions.Types.DatagramReceiveOffload {
    public static var datagramReceiveOffload: Self { .init() }
}

/// - seealso: `DatagramReceiveSegmentSize`.
extension ChannelOption where Self == ChannelOptions.Types.DatagramReceiveSegmentSize {
    public static var datagramReceiveSegmentSize: Self { .init() }
}

/// - seealso: `ExplicitCongestionNotificationsOption`.
extension ChannelOption where Self == ChannelOptions.Types.ExplicitCongestionNotificationsOption {
    public static var explicitCongestionNotification: Self { .init() }
}

/// - seealso: `ReceivePacketInfo`.
extension ChannelOption where Self == ChannelOptions.Types.ReceivePacketInfo {
    public static var receivePacketInfo: Self { .init() }
}

/// - seealso: `BufferedWritableBytesOption`
extension ChannelOption where Self == ChannelOptions.Types.BufferedWritableBytesOption {
    public static var bufferedWritableBytes: Self { .init() }
}

extension ChannelOptions {
    /// A type-safe storage facility for `ChannelOption`s. You will only ever need this if you implement your own
    /// `Channel` that needs to store `ChannelOption`s.
    public struct Storage: Sendable {
        @usableFromInline
        internal var _storage:
            [(
                any ChannelOption,
                (any Sendable, @Sendable (Channel) -> (any ChannelOption, any Sendable) -> EventLoopFuture<Void>)
            )]

        public init() {
            self._storage = []
            self._storage.reserveCapacity(2)
        }

        /// Add `Options`, a `ChannelOption` to the `ChannelOptions.Storage`.
        ///
        /// - Parameters:
        ///    - newKey: the key for the option
        ///    - newValue: the value for the option
        @inlinable
        public mutating func append<Option: ChannelOption>(key newKey: Option, value newValue: Option.Value) {
            @Sendable
            func applier(_ t: Channel) -> (any ChannelOption, any Sendable) -> EventLoopFuture<Void> {
                { (option, value) in
                    t.setOption(option as! Option, value: value as! Option.Value)
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
        /// - Parameters:
        ///    - channel: The `Channel` to apply the `ChannelOption`s to
        /// - Returns:
        ///    - An `EventLoopFuture` that is fulfilled when all `ChannelOption`s have been applied to the `Channel`.
        public func applyAllChannelOptions(to channel: Channel) -> EventLoopFuture<Void> {
            let applyPromise = channel.eventLoop.makePromise(of: Void.self)
            let it = self._storage.makeIterator()

            @Sendable
            func applyNext(
                iterator: IndexingIterator<
                    [(
                        any ChannelOption,
                        (
                            any Sendable,
                            @Sendable (any Channel) -> (any ChannelOption, any Sendable) -> EventLoopFuture<Void>
                        )
                    )]
                >
            ) {
                var iterator = iterator
                guard let (key, (value, applier)) = iterator.next() else {
                    // If we reached the end, everything is applied.
                    applyPromise.succeed(())
                    return
                }
                let it = iterator

                applier(channel)(key, value).map {
                    applyNext(
                        iterator: it
                    )
                }.cascadeFailure(to: applyPromise)
            }
            applyNext(iterator: it)

            return applyPromise.futureResult
        }

        /// Remove all options with the given `key`.
        ///
        /// Calling this function has the effect of removing all instances of a ``ChannelOption``
        /// from the ``ChannelOptions/Storage``, as if none had been added. This is useful in rare
        /// cases where a bootstrap knows that some configuration must purge options of a certain kind.
        ///
        /// - Parameters:
        ///   - key: The ``ChannelOption`` to remove.
        public mutating func remove<Option: ChannelOption>(key: Option) {
            self._storage.removeAll(where: { existingKey, _ in
                (existingKey as? Option) == key
            })
        }
    }
}
