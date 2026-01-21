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
#if canImport(Darwin)
import Darwin
#elseif os(Linux) || os(Android)
#if canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(Bionic)
@preconcurrency import Bionic
#endif
import CNIOLinux
#elseif os(OpenBSD)
@preconcurrency import Glibc
import CNIOOpenBSD
#elseif os(Windows)
import WinSDK
#elseif canImport(WASILibc)
@preconcurrency import WASILibc
#else
#error("The Socket Option provider module was unable to identify your C library.")
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
/// - Note: Like the `Channel` protocol, all methods in this protocol are
///     thread-safe.
public protocol SocketOptionProvider: _NIOPreconcurrencySendable {
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
    /// - Parameters:
    ///   - level: The socket option level, e.g. `SOL_SOCKET` or `IPPROTO_IP`.
    ///   - name: The name of the socket option, e.g. `SO_REUSEADDR`.
    ///   - value: The value to set the socket option to.
    /// - Returns: An `EventLoopFuture` that fires when the option has been set,
    ///     or if an error has occurred.
    @preconcurrency
    func unsafeSetSocketOption<Value: Sendable>(
        level: SocketOptionLevel,
        name: SocketOptionName,
        value: Value
    ) -> EventLoopFuture<Void>
    #endif

    /// Set a socket option for a given level and name to the specified value.
    ///
    /// This function is not memory-safe: if you set the generic type parameter incorrectly,
    /// this function will still execute, and this can cause you to incorrectly interpret memory
    /// and thereby read uninitialized or invalid memory. If at all possible, please use one of
    /// the safe functions defined by this protocol.
    ///
    /// - Parameters:
    ///   - level: The socket option level, e.g. `SOL_SOCKET` or `IPPROTO_IP`.
    ///   - name: The name of the socket option, e.g. `SO_REUSEADDR`.
    ///   - value: The value to set the socket option to.
    /// - Returns: An `EventLoopFuture` that fires when the option has been set,
    ///     or if an error has occurred.
    @preconcurrency
    func unsafeSetSocketOption<Value: Sendable>(
        level: NIOBSDSocket.OptionLevel,
        name: NIOBSDSocket.Option,
        value: Value
    ) -> EventLoopFuture<Void>

    #if !os(Windows)
    /// Obtain the value of the socket option for the given level and name.
    ///
    /// This function is not memory-safe: if you set the generic type parameter incorrectly,
    /// this function will still execute, and this can cause you to incorrectly interpret memory
    /// and thereby read uninitialized or invalid memory. If at all possible, please use one of
    /// the safe functions defined by this protocol.
    ///
    /// - Parameters:
    ///   - level: The socket option level, e.g. `SOL_SOCKET` or `IPPROTO_IP`.
    ///   - name: The name of the socket option, e.g. `SO_REUSEADDR`.
    /// - Returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    @preconcurrency
    func unsafeGetSocketOption<Value: Sendable>(
        level: SocketOptionLevel,
        name: SocketOptionName
    ) -> EventLoopFuture<Value>
    #endif

    /// Obtain the value of the socket option for the given level and name.
    ///
    /// This function is not memory-safe: if you set the generic type parameter incorrectly,
    /// this function will still execute, and this can cause you to incorrectly interpret memory
    /// and thereby read uninitialized or invalid memory. If at all possible, please use one of
    /// the safe functions defined by this protocol.
    ///
    /// - Parameters:
    ///   - level: The socket option level, e.g. `SOL_SOCKET` or `IPPROTO_IP`.
    ///   - name: The name of the socket option, e.g. `SO_REUSEADDR`.
    /// - Returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    @preconcurrency
    func unsafeGetSocketOption<Value: Sendable>(
        level: NIOBSDSocket.OptionLevel,
        name: NIOBSDSocket.Option
    ) -> EventLoopFuture<Value>
}

#if !os(Windows)
extension SocketOptionProvider {
    func unsafeSetSocketOption<Value: Sendable>(
        level: NIOBSDSocket.OptionLevel,
        name: NIOBSDSocket.Option,
        value: Value
    ) -> EventLoopFuture<Void> {
        self.unsafeSetSocketOption(
            level: SocketOptionLevel(level.rawValue),
            name: SocketOptionName(name.rawValue),
            value: value
        )
    }

    func unsafeGetSocketOption<Value: Sendable>(
        level: NIOBSDSocket.OptionLevel,
        name: NIOBSDSocket.Option
    ) -> EventLoopFuture<Value> {
        self.unsafeGetSocketOption(level: SocketOptionLevel(level.rawValue), name: SocketOptionName(name.rawValue))
    }
}
#endif

enum SocketOptionProviderError: Swift.Error {
    case unsupported
}

#if canImport(WASILibc)
public typealias NIOLinger = Never
#else
public typealias NIOLinger = linger
#endif

// MARK:- Safe helper methods.
// Hello code reader! All the methods in this extension are "safe" wrapper methods that define the correct
// types for `setSocketOption` and `getSocketOption` and call those methods on behalf of the user. These
// wrapper methods are memory safe. All of these methods are basically identical, and have been copy-pasted
// around. As a result, if you change one, you should probably change them all.
//
// You are welcome to add more helper methods here, but each helper method you add must be tested.
//
// Please note that to work around a Swift compiler issue regarding lookup of the Sendability of
// libc types across modules, the actual calls to `unsafeSetSocketOption` and `unsafeGetSocketOption`
// _must_ be made inside non-`public` non-`@inlinable` methods. Otherwise we'll produce crashes
// in release mode. NIO's integration tests are a good canary for this: if you call your method
// from an alloc counter test in the integration tests, it'll crash if you messed it up.
extension SocketOptionProvider {
    /// Sets the socket option SO_LINGER to `value`.
    ///
    /// - Parameters:
    ///   - value: The value to set SO_LINGER to.
    /// - Returns: An `EventLoopFuture` that fires when the option has been set,
    ///     or if an error has occurred.
    public func setSoLinger(_ value: linger) -> EventLoopFuture<Void> {
        self._setSoLinger(value)
    }

    /// Gets the value of the socket option SO_LINGER.
    ///
    /// - Returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    public func getSoLinger() -> EventLoopFuture<NIOLinger> {
        self._getSoLinger()
    }

    /// Sets the socket option IP_MULTICAST_IF to `value`.
    ///
    /// - Parameters:
    ///   - value: The value to set IP_MULTICAST_IF to.
    /// - Returns: An `EventLoopFuture` that fires when the option has been set,
    ///     or if an error has occurred.
    public func setIPMulticastIF(_ value: in_addr) -> EventLoopFuture<Void> {
        self._setIPMulticastIF(value)
    }

    /// Gets the value of the socket option IP_MULTICAST_IF.
    ///
    /// - Returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    public func getIPMulticastIF() -> EventLoopFuture<in_addr> {
        self._getIPMulticastIF()
    }

    /// Sets the socket option IP_MULTICAST_TTL to `value`.
    ///
    /// - Parameters:
    ///   - value: The value to set IP_MULTICAST_TTL to.
    /// - Returns: An `EventLoopFuture` that fires when the option has been set,
    ///     or if an error has occurred.
    public func setIPMulticastTTL(_ value: CUnsignedChar) -> EventLoopFuture<Void> {
        self._setIPMulticastTTL(value)
    }

    /// Gets the value of the socket option IP_MULTICAST_TTL.
    ///
    /// - Returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    public func getIPMulticastTTL() -> EventLoopFuture<CUnsignedChar> {
        self._getIPMulticastTTL()
    }

    /// Sets the socket option IP_MULTICAST_LOOP to `value`.
    ///
    /// - Parameters:
    ///   - value: The value to set IP_MULTICAST_LOOP to.
    /// - Returns: An `EventLoopFuture` that fires when the option has been set,
    ///     or if an error has occurred.
    public func setIPMulticastLoop(_ value: CUnsignedChar) -> EventLoopFuture<Void> {
        self._setIPMulticastLoop(value)
    }

    /// Gets the value of the socket option IP_MULTICAST_LOOP.
    ///
    /// - Returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    public func getIPMulticastLoop() -> EventLoopFuture<CUnsignedChar> {
        self._getIPMulticastLoop()
    }

    /// Sets the socket option IPV6_MULTICAST_IF to `value`.
    ///
    /// - Parameters:
    ///   - value: The value to set IPV6_MULTICAST_IF to.
    /// - Returns: An `EventLoopFuture` that fires when the option has been set,
    ///     or if an error has occurred.
    public func setIPv6MulticastIF(_ value: CUnsignedInt) -> EventLoopFuture<Void> {
        self._setIPv6MulticastIF(value)
    }

    /// Gets the value of the socket option IPV6_MULTICAST_IF.
    ///
    /// - Returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    public func getIPv6MulticastIF() -> EventLoopFuture<CUnsignedInt> {
        self._getIPv6MulticastIF()
    }

    /// Sets the socket option IPV6_MULTICAST_HOPS to `value`.
    ///
    /// - Parameters:
    ///   - value: The value to set IPV6_MULTICAST_HOPS to.
    /// - Returns: An `EventLoopFuture` that fires when the option has been set,
    ///     or if an error has occurred.
    public func setIPv6MulticastHops(_ value: CInt) -> EventLoopFuture<Void> {
        self._setIPv6MulticastHops(value)
    }

    /// Gets the value of the socket option IPV6_MULTICAST_HOPS.
    ///
    /// - Returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    public func getIPv6MulticastHops() -> EventLoopFuture<CInt> {
        self._getIPv6MulticastHops()
    }

    /// Sets the socket option IPV6_MULTICAST_LOOP to `value`.
    ///
    /// - Parameters:
    ///   - value: The value to set IPV6_MULTICAST_LOOP to.
    /// - Returns: An `EventLoopFuture` that fires when the option has been set,
    ///     or if an error has occurred.
    public func setIPv6MulticastLoop(_ value: CUnsignedInt) -> EventLoopFuture<Void> {
        self._setIPv6MulticastLoop(value)
    }

    /// Gets the value of the socket option IPV6_MULTICAST_LOOP.
    ///
    /// - Returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    public func getIPv6MulticastLoop() -> EventLoopFuture<CUnsignedInt> {
        self._getIPv6MulticastLoop()
    }

    #if os(Linux) || os(FreeBSD) || os(Android)
    /// Gets the value of the socket option TCP_INFO.
    ///
    /// This socket option cannot be set.
    ///
    /// - Returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    public func getTCPInfo() -> EventLoopFuture<tcp_info> {
        self._getTCPInfo()
    }
    #endif

    #if canImport(Darwin)
    /// Gets the value of the socket option TCP_CONNECTION_INFO.
    ///
    /// This socket option cannot be set.
    ///
    /// - Returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    public func getTCPConnectionInfo() -> EventLoopFuture<tcp_connection_info> {
        self._getTCPConnectionInfo()
    }
    #endif

    #if os(Linux)
    /// Gets the value of the socket option MPTCP_INFO.
    ///
    /// This socket option cannot be set.
    ///
    /// - Returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    public func getMPTCPInfo() -> EventLoopFuture<mptcp_info> {
        self._getMPTCPInfo()
    }
    #endif

    // MARK: Non-public non-inlinable actual implementations for the above.
    //
    // As discussed above, these are needed to work around a compiler issue
    // that was present at least up to the 6.0 compiler series. This prevents
    // the specialization being emitted in the caller code, which is unfortunate,
    // but it also ensures that we avoid the crash. We should remove these when
    // they're no longer needed.

    /// Sets the socket option SO_LINGER to `value`.
    ///
    /// - Parameters:
    ///   - value: The value to set SO_LINGER to.
    /// - Returns: An `EventLoopFuture` that fires when the option has been set,
    ///     or if an error has occurred.
    private func _setSoLinger(_ value: linger) -> EventLoopFuture<Void> {
        #if os(WASI)
        self.eventLoop.makeFailedFuture(SocketOptionProviderError.unsupported)
        #else
        self.unsafeSetSocketOption(level: .socket, name: .so_linger, value: value)
        #endif
    }

    /// Gets the value of the socket option SO_LINGER.
    ///
    /// - Returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    private func _getSoLinger() -> EventLoopFuture<NIOLinger> {
        #if os(WASI)
        self.eventLoop.makeFailedFuture(SocketOptionProviderError.unsupported)
        #else
        self.unsafeGetSocketOption(level: .socket, name: .so_linger)
        #endif
    }

    /// Sets the socket option IP_MULTICAST_IF to `value`.
    ///
    /// - Parameters:
    ///   - value: The value to set IP_MULTICAST_IF to.
    /// - Returns: An `EventLoopFuture` that fires when the option has been set,
    ///     or if an error has occurred.
    private func _setIPMulticastIF(_ value: in_addr) -> EventLoopFuture<Void> {
        self.unsafeSetSocketOption(level: .ip, name: .ip_multicast_if, value: value)
    }

    /// Gets the value of the socket option IP_MULTICAST_IF.
    ///
    /// - Returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    private func _getIPMulticastIF() -> EventLoopFuture<in_addr> {
        self.unsafeGetSocketOption(level: .ip, name: .ip_multicast_if)
    }

    /// Sets the socket option IP_MULTICAST_TTL to `value`.
    ///
    /// - Parameters:
    ///   - value: The value to set IP_MULTICAST_TTL to.
    /// - Returns: An `EventLoopFuture` that fires when the option has been set,
    ///     or if an error has occurred.
    private func _setIPMulticastTTL(_ value: CUnsignedChar) -> EventLoopFuture<Void> {
        self.unsafeSetSocketOption(level: .ip, name: .ip_multicast_ttl, value: value)
    }

    /// Gets the value of the socket option IP_MULTICAST_TTL.
    ///
    /// - Returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    private func _getIPMulticastTTL() -> EventLoopFuture<CUnsignedChar> {
        self.unsafeGetSocketOption(level: .ip, name: .ip_multicast_ttl)
    }

    /// Sets the socket option IP_MULTICAST_LOOP to `value`.
    ///
    /// - Parameters:
    ///   - value: The value to set IP_MULTICAST_LOOP to.
    /// - Returns: An `EventLoopFuture` that fires when the option has been set,
    ///     or if an error has occurred.
    private func _setIPMulticastLoop(_ value: CUnsignedChar) -> EventLoopFuture<Void> {
        self.unsafeSetSocketOption(level: .ip, name: .ip_multicast_loop, value: value)
    }

    /// Gets the value of the socket option IP_MULTICAST_LOOP.
    ///
    /// - Returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    private func _getIPMulticastLoop() -> EventLoopFuture<CUnsignedChar> {
        self.unsafeGetSocketOption(level: .ip, name: .ip_multicast_loop)
    }

    /// Sets the socket option IPV6_MULTICAST_IF to `value`.
    ///
    /// - Parameters:
    ///   - value: The value to set IPV6_MULTICAST_IF to.
    /// - Returns: An `EventLoopFuture` that fires when the option has been set,
    ///     or if an error has occurred.
    private func _setIPv6MulticastIF(_ value: CUnsignedInt) -> EventLoopFuture<Void> {
        self.unsafeSetSocketOption(level: .ipv6, name: .ipv6_multicast_if, value: value)
    }

    /// Gets the value of the socket option IPV6_MULTICAST_IF.
    ///
    /// - Returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    private func _getIPv6MulticastIF() -> EventLoopFuture<CUnsignedInt> {
        self.unsafeGetSocketOption(level: .ipv6, name: .ipv6_multicast_if)
    }

    /// Sets the socket option IPV6_MULTICAST_HOPS to `value`.
    ///
    /// - Parameters:
    ///   - value: The value to set IPV6_MULTICAST_HOPS to.
    /// - Returns: An `EventLoopFuture` that fires when the option has been set,
    ///     or if an error has occurred.
    private func _setIPv6MulticastHops(_ value: CInt) -> EventLoopFuture<Void> {
        self.unsafeSetSocketOption(level: .ipv6, name: .ipv6_multicast_hops, value: value)
    }

    /// Gets the value of the socket option IPV6_MULTICAST_HOPS.
    ///
    /// - Returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    private func _getIPv6MulticastHops() -> EventLoopFuture<CInt> {
        self.unsafeGetSocketOption(level: .ipv6, name: .ipv6_multicast_hops)
    }

    /// Sets the socket option IPV6_MULTICAST_LOOP to `value`.
    ///
    /// - Parameters:
    ///   - value: The value to set IPV6_MULTICAST_LOOP to.
    /// - Returns: An `EventLoopFuture` that fires when the option has been set,
    ///     or if an error has occurred.
    private func _setIPv6MulticastLoop(_ value: CUnsignedInt) -> EventLoopFuture<Void> {
        self.unsafeSetSocketOption(level: .ipv6, name: .ipv6_multicast_loop, value: value)
    }

    /// Gets the value of the socket option IPV6_MULTICAST_LOOP.
    ///
    /// - Returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    private func _getIPv6MulticastLoop() -> EventLoopFuture<CUnsignedInt> {
        self.unsafeGetSocketOption(level: .ipv6, name: .ipv6_multicast_loop)
    }

    #if os(Linux) || os(FreeBSD) || os(Android)
    /// Gets the value of the socket option TCP_INFO.
    ///
    /// This socket option cannot be set.
    ///
    /// - Returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    private func _getTCPInfo() -> EventLoopFuture<tcp_info> {
        self.unsafeGetSocketOption(level: .tcp, name: .tcp_info)
    }
    #endif

    #if canImport(Darwin)
    /// Gets the value of the socket option TCP_CONNECTION_INFO.
    ///
    /// This socket option cannot be set.
    ///
    /// - Returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    private func _getTCPConnectionInfo() -> EventLoopFuture<tcp_connection_info> {
        self.unsafeGetSocketOption(level: .tcp, name: .tcp_connection_info)
    }
    #endif

    #if os(Linux)
    /// Gets the value of the socket option MPTCP_INFO.
    ///
    /// This socket option cannot be set.
    ///
    /// - Returns: An `EventLoopFuture` containing the value of the socket option, or
    ///     any error that occurred while retrieving the socket option.
    private func _getMPTCPInfo() -> EventLoopFuture<mptcp_info> {
        self.unsafeGetSocketOption(level: .mptcp, name: .mptcp_info)
    }
    #endif
}
