//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#elseif os(Linux) || os(Android)
import Glibc
#endif

/// This protocol defines an object, most commonly a `Channel`, that supports
/// setting and getting socket options (via `setsockopt`/`getsockopt` or similar).
/// It provides a strongly typed API that makes working with larger, less-common
/// socket options easier than the `ChannelOption` API allows.
///
/// The API is divided into two portions. For socket options that NIO has prior
/// knowledge about, the API has strongly and safely typed APIs that only allow
/// users to use the exact correct type for the socket option. This will ensure
/// that the API is safe to use, and these are encouraged where possible.
///
/// These safe APIs are built on top of an "unsafe" API that is also exposed to
/// users as part of this protocol. The "unsafe" API is unsafe in the same way
/// that `UnsafePointer` is: incorrect use of the API allows all kinds of
/// memory-unsafe behaviour. This API is necessary for socket options that NIO
/// does not have prior knowledge of, but wherever possible users are discouraged
/// from using it.
///
/// ### Relationship to SocketOption
///
/// All `Channel` objects that implement this protocol should also support the
/// `SocketOption` `ChannelOption` for simple socket options (those with C `int`
/// values). These are the most common socket option types, and so this `ChannelOption`
/// represents a convenient shorthand for using this protocol where the type allows,
/// as well as avoiding the need to cast to this protocol.
///
/// - note: Like the `Channel` protocol, all methods in this protocol are
///     thread-safe.
public protocol SocketOptionProvider {
    /// The `EventLoop` which is used by this `SocketOptionProvider` for execution.
    var eventLoop: EventLoop { get }

    #if !os(Windows)
        /// Set a socket option for a given level and name to the specified value.
        ///
        /// This function is not memory-safe: if you set the generic type parameter incorrectly,
        /// this function will still execute, and this can cause you to incorrectly interpret memory
        /// and thereby read uninitialized or invalid memory. If at all possible, please use one of
        /// the safe functions defined by this protocol.
        ///
        /// - parameters:
        ///     - level: The socket option level, e.g. `SOL_SOCKET` or `IPPROTO_IP`.
        ///     - name: The name of the socket option, e.g. `SO_REUSEADDR`.
        ///     - value: The value to set the socket option to.
        /// - returns: An `EventLoopFuture` that fires when the option has been set,
        ///     or if an error has occurred.
        func unsafeSetSocketOption<Value>(level: SocketOptionLevel, name: SocketOptionName, value: Value) -> EventLoopFuture<Void>
    #endif

    /// Set a socket option for a given level and name to the specified value.
    ///
    /// This function is not memory-safe: if you set the generic type parameter incorrectly,
    /// this function will still execute, and this can cause you to incorrectly interpret memory
    /// and thereby read uninitialized or invalid memory. If at all possible, please use one of
    /// the safe functions defined by this protocol.
    ///
    /// - parameters:
    ///     - level: The socket option level, e.g. `SOL_SOCKET` or `IPPROTO_IP`.
    ///     - name: The name of the socket option, e.g. `SO_REUSEADDR`.
    ///     - value: The value to set the socket option to.
    /// - returns: An `EventLoopFuture` that fires when the option has been set,
    ///     or if an error has occurred.
    func unsafeSetSocketOption<Value>(level: NIOBSDSocket.OptionLevel, name: NIOBSDSocket.Option, value: Value) -> EventLoopFuture<Void>

    #if !os(Windows)
        /// Obtain the value of the socket option for the given level and name.
        ///
        /// This function is not memory-safe: if you set the generic type parameter incorrectly,
        /// this function will still execute, and this can cause you to incorrectly interpret memory
        /// and thereby read uninitialized or invalid memory. If at all possible, please use one of
        /// the safe functions defined by this protocol.
        ///
        /// - parameters:
        ///     - level: The socket option level, e.g. `SOL_SOCKET` or `IPPROTO_IP`.
        ///     - name: The name of the socket option, e.g. `SO_REUSEADDR`.
        /// - returns: An `EventLoopFuture` containing the value of the socket option, or
        ///     any error that occurred while retrieving the socket option.
        func unsafeGetSocketOption<Value>(level: SocketOptionLevel, name: SocketOptionName) -> EventLoopFuture<Value>
    #endif

    /// Obtain the value of the socket option for the given level and name.
    ///
    /// This function is not memory-safe: if you set the generic type parameter incorrectly,
    /// this function will still execute, and this can cause you to incorrectly interpret memory
    /// and thereby read uninitialized or invalid memory. If at all possible, please use one of
    /// the safe functions defined by this protocol.
    ///
    /// - parameters:
    ///     - level: The socket option level, e.g. `SOL_SOCKET` or `IPPROTO_IP`.
    ///     - name: The name of the socket option, e.g. `SO_REUSEADDR`.
    /// - returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    func unsafeGetSocketOption<Value>(level: NIOBSDSocket.OptionLevel, name: NIOBSDSocket.Option) -> EventLoopFuture<Value>
}

#if !os(Windows)
    extension SocketOptionProvider {
        func unsafeSetSocketOption<Value>(level: NIOBSDSocket.OptionLevel, name: NIOBSDSocket.Option, value: Value) -> EventLoopFuture<Void> {
            return self.unsafeSetSocketOption(level: SocketOptionLevel(level.rawValue), name: SocketOptionName(name.rawValue), value: value)
        }

        func unsafeGetSocketOption<Value>(level: NIOBSDSocket.OptionLevel, name: NIOBSDSocket.Option) -> EventLoopFuture<Value> {
            return self.unsafeGetSocketOption(level: SocketOptionLevel(level.rawValue), name: SocketOptionName(name.rawValue))
        }
    }
#endif

// MARK:- Safe helper methods.
// Hello code reader! All the methods in this extension are "safe" wrapper methods that define the correct
// types for `setSocketOption` and `getSocketOption` and call those methods on behalf of the user. These
// wrapper methods are memory safe. All of these methods are basically identical, and have been copy-pasted
// around. As a result, if you change one, you should probably change them all.
//
// You are welcome to add more helper methods here, but each helper method you add must be tested.
extension SocketOptionProvider {
    /// Sets the socket option SO_LINGER to `value`.
    ///
    /// - parameters:
    ///     - value: The value to set SO_LINGER to.
    /// - returns: An `EventLoopFuture` that fires when the option has been set,
    ///     or if an error has occurred.
    public func setSoLinger(_ value: linger) -> EventLoopFuture<Void> {
        return self.unsafeSetSocketOption(level: .socket, name: .so_linger, value: value)
    }

    /// Gets the value of the socket option SO_LINGER.
    ///
    /// - returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    public func getSoLinger() -> EventLoopFuture<linger> {
        return self.unsafeGetSocketOption(level: .socket, name: .so_linger)
    }

    /// Sets the socket option IP_MULTICAST_IF to `value`.
    ///
    /// - parameters:
    ///     - value: The value to set IP_MULTICAST_IF to.
    /// - returns: An `EventLoopFuture` that fires when the option has been set,
    ///     or if an error has occurred.
    public func setIPMulticastIF(_ value: in_addr) -> EventLoopFuture<Void> {
        return self.unsafeSetSocketOption(level: .ip, name: .ip_multicast_if, value: value)
    }

    /// Gets the value of the socket option IP_MULTICAST_IF.
    ///
    /// - returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    public func getIPMulticastIF() -> EventLoopFuture<in_addr> {
        return self.unsafeGetSocketOption(level: .ip, name: .ip_multicast_if)
    }

    /// Sets the socket option IP_MULTICAST_TTL to `value`.
    ///
    /// - parameters:
    ///     - value: The value to set IP_MULTICAST_TTL to.
    /// - returns: An `EventLoopFuture` that fires when the option has been set,
    ///     or if an error has occurred.
    public func setIPMulticastTTL(_ value: CUnsignedChar) -> EventLoopFuture<Void> {
        return self.unsafeSetSocketOption(level: .ip, name: .ip_multicast_ttl, value: value)
    }

    /// Gets the value of the socket option IP_MULTICAST_TTL.
    ///
    /// - returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    public func getIPMulticastTTL() -> EventLoopFuture<CUnsignedChar> {
        return self.unsafeGetSocketOption(level: .ip, name: .ip_multicast_ttl)
    }

    /// Sets the socket option IP_MULTICAST_LOOP to `value`.
    ///
    /// - parameters:
    ///     - value: The value to set IP_MULTICAST_LOOP to.
    /// - returns: An `EventLoopFuture` that fires when the option has been set,
    ///     or if an error has occurred.
    public func setIPMulticastLoop(_ value: CUnsignedChar) -> EventLoopFuture<Void> {
        return self.unsafeSetSocketOption(level: .ip, name: .ip_multicast_loop, value: value)
    }

    /// Gets the value of the socket option IP_MULTICAST_LOOP.
    ///
    /// - returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    public func getIPMulticastLoop() -> EventLoopFuture<CUnsignedChar> {
        return self.unsafeGetSocketOption(level: .ip, name: .ip_multicast_loop)
    }

    /// Sets the socket option IPV6_MULTICAST_IF to `value`.
    ///
    /// - parameters:
    ///     - value: The value to set IPV6_MULTICAST_IF to.
    /// - returns: An `EventLoopFuture` that fires when the option has been set,
    ///     or if an error has occurred.
    public func setIPv6MulticastIF(_ value: CUnsignedInt) -> EventLoopFuture<Void> {
        return self.unsafeSetSocketOption(level: .ipv6, name: .ipv6_multicast_if, value: value)
    }

    /// Gets the value of the socket option IPV6_MULTICAST_IF.
    ///
    /// - returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    public func getIPv6MulticastIF() -> EventLoopFuture<CUnsignedInt> {
        return self.unsafeGetSocketOption(level: .ipv6, name: .ipv6_multicast_if)
    }

    /// Sets the socket option IPV6_MULTICAST_HOPS to `value`.
    ///
    /// - parameters:
    ///     - value: The value to set IPV6_MULTICAST_HOPS to.
    /// - returns: An `EventLoopFuture` that fires when the option has been set,
    ///     or if an error has occurred.
    public func setIPv6MulticastHops(_ value: CInt) -> EventLoopFuture<Void> {
        return self.unsafeSetSocketOption(level: .ipv6, name: .ipv6_multicast_hops, value: value)
    }

    /// Gets the value of the socket option IPV6_MULTICAST_HOPS.
    ///
    /// - returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    public func getIPv6MulticastHops() -> EventLoopFuture<CInt> {
        return self.unsafeGetSocketOption(level: .ipv6, name: .ipv6_multicast_hops)
    }

    /// Sets the socket option IPV6_MULTICAST_LOOP to `value`.
    ///
    /// - parameters:
    ///     - value: The value to set IPV6_MULTICAST_LOOP to.
    /// - returns: An `EventLoopFuture` that fires when the option has been set,
    ///     or if an error has occurred.
    public func setIPv6MulticastLoop(_ value: CUnsignedInt) -> EventLoopFuture<Void> {
        return self.unsafeSetSocketOption(level: .ipv6, name: .ipv6_multicast_loop, value: value)
    }

    /// Gets the value of the socket option IPV6_MULTICAST_LOOP.
    ///
    /// - returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    public func getIPv6MulticastLoop() -> EventLoopFuture<CUnsignedInt> {
        return self.unsafeGetSocketOption(level: .ipv6, name: .ipv6_multicast_loop)
    }

    #if os(Linux) || os(FreeBSD) || os(Android)
        /// Gets the value of the socket option TCP_INFO.
        ///
        /// This socket option cannot be set.
        ///
        /// - returns: An `EventLoopFuture` containing the value of the socket option, or
        ///     any error that occurred while retrieving the socket option.
        public func getTCPInfo() -> EventLoopFuture<tcp_info> {
            return self.unsafeGetSocketOption(level: .tcp, name: .tcp_info)
        }
    #endif

    #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
        /// Gets the value of the socket option TCP_CONNECTION_INFO.
        ///
        /// This socket option cannot be set.
        ///
        /// - returns: An `EventLoopFuture` containing the value of the socket option, or
        ///     any error that occurred while retrieving the socket option.
        public func getTCPConnectionInfo() -> EventLoopFuture<tcp_connection_info> {
            return self.unsafeGetSocketOption(level: .tcp, name: .tcp_connection_info)
        }
    #endif
}
