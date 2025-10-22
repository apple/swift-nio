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

#if os(Windows)
import ucrt

import let WinSDK.AF_INET
import let WinSDK.AF_INET6

import let WinSDK.INET_ADDRSTRLEN
import let WinSDK.INET6_ADDRSTRLEN

import func WinSDK.FreeAddrInfoW
import func WinSDK.GetAddrInfoW

import struct WinSDK.ADDRESS_FAMILY
import struct WinSDK.ADDRINFOW
import struct WinSDK.IN_ADDR
import struct WinSDK.IN6_ADDR

import struct WinSDK.sockaddr
import struct WinSDK.sockaddr_in
import struct WinSDK.sockaddr_in6
import struct WinSDK.sockaddr_storage
import struct WinSDK.sockaddr_un

import typealias WinSDK.u_short

private typealias in_addr = WinSDK.IN_ADDR
private typealias in6_addr = WinSDK.IN6_ADDR
private typealias in_port_t = WinSDK.u_short
private typealias sa_family_t = WinSDK.ADDRESS_FAMILY
#elseif canImport(Darwin)
import Darwin
#elseif os(Linux) || os(FreeBSD) || os(Android)
#if canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(Android)
@preconcurrency import Android
#endif
import CNIOLinux
#elseif os(OpenBSD)
@preconcurrency import Glibc
import CNIOOpenBSD
#elseif canImport(WASILibc)
@preconcurrency import WASILibc
#else
#error("The Socket Addresses module was unable to identify your C library.")
#endif

/// Special `Error` that may be thrown if we fail to create a `SocketAddress`.
public enum SocketAddressError: Error, Equatable, Hashable {
    /// The host is unknown (could not be resolved).
    case unknown(host: String, port: Int)
    /// The requested `SocketAddress` is not supported.
    case unsupported
    /// The requested UDS path is too long.
    case unixDomainSocketPathTooLong
    /// Unable to parse a given IP string
    case failedToParseIPString(String)
}

extension SocketAddressError {
    /// Unable to parse a given IP ByteBuffer
    public struct FailedToParseIPByteBuffer: Error, Hashable {
        public var address: ByteBuffer

        public init(address: ByteBuffer) {
            self.address = address
        }
    }
}

/// Represent a socket address to which we may want to connect or bind.
public enum SocketAddress: CustomStringConvertible, Sendable {

    /// A single IPv4 address for `SocketAddress`.
    public struct IPv4Address {
        private let _storage: Box<(address: sockaddr_in, host: String)>

        /// The libc socket address for an IPv4 address.
        public var address: sockaddr_in { _storage.value.address }

        /// The host this address is for, if known.
        public var host: String { _storage.value.host }

        fileprivate init(address: sockaddr_in, host: String) {
            self._storage = Box((address: address, host: host))
        }
    }

    /// A single IPv6 address for `SocketAddress`.
    public struct IPv6Address {
        private let _storage: Box<(address: sockaddr_in6, host: String)>

        /// The libc socket address for an IPv6 address.
        public var address: sockaddr_in6 { _storage.value.address }

        /// The host this address is for, if known.
        public var host: String { _storage.value.host }

        fileprivate init(address: sockaddr_in6, host: String) {
            self._storage = Box((address: address, host: host))
        }
    }

    /// A single Unix socket address for `SocketAddress`.
    public struct UnixSocketAddress: Sendable {
        private let _storage: Box<sockaddr_un>

        /// The libc socket address for a Unix Domain Socket.
        public var address: sockaddr_un { _storage.value }

        fileprivate init(address: sockaddr_un) {
            self._storage = Box(address)
        }
    }

    /// An IPv4 `SocketAddress`.
    case v4(IPv4Address)

    /// An IPv6 `SocketAddress`.
    case v6(IPv6Address)

    /// An UNIX Domain `SocketAddress`.
    case unixDomainSocket(UnixSocketAddress)

    /// A human-readable description of this `SocketAddress`. Mostly useful for logging.
    public var description: String {
        let addressString: String
        let port: String
        let host: String?
        let type: String
        switch self {
        case .v4(let addr):
            host = addr.host.isEmpty ? nil : addr.host
            type = "IPv4"
            var mutAddr = addr.address.sin_addr
            // this uses inet_ntop which is documented to only fail if family is not AF_INET or AF_INET6 (or ENOSPC)
            addressString = try! descriptionForAddress(family: .inet, bytes: &mutAddr, length: Int(INET_ADDRSTRLEN))

            port = "\(self.port!)"
        case .v6(let addr):
            host = addr.host.isEmpty ? nil : addr.host
            type = "IPv6"
            var mutAddr = addr.address.sin6_addr
            // this uses inet_ntop which is documented to only fail if family is not AF_INET or AF_INET6 (or ENOSPC)
            addressString = try! descriptionForAddress(family: .inet6, bytes: &mutAddr, length: Int(INET6_ADDRSTRLEN))

            port = "\(self.port!)"
        case .unixDomainSocket(_):
            host = nil
            type = "UDS"
            return "[\(type)]\(self.pathname ?? "")"
        }

        return "[\(type)]\(host.map { "\($0)/\(addressString):" } ?? "\(addressString):")\(port)"
    }

    @available(*, deprecated, renamed: "SocketAddress.protocol")
    public var protocolFamily: Int32 {
        Int32(self.protocol.rawValue)
    }

    /// Returns the protocol family as defined in `man 2 socket` of this `SocketAddress`.
    public var `protocol`: NIOBSDSocket.ProtocolFamily {
        switch self {
        case .v4:
            return .inet
        case .v6:
            return .inet6
        case .unixDomainSocket:
            #if os(WASI)
            fatalError("unix domain sockets are currently not supported by WASILibc")
            #else
            return .unix
            #endif
        }
    }

    /// Get the IP address as a string
    public var ipAddress: String? {
        switch self {
        case .v4(let addr):
            var mutAddr = addr.address.sin_addr
            // this uses inet_ntop which is documented to only fail if family is not AF_INET or AF_INET6 (or ENOSPC)
            return try! descriptionForAddress(family: .inet, bytes: &mutAddr, length: Int(INET_ADDRSTRLEN))
        case .v6(let addr):
            var mutAddr = addr.address.sin6_addr
            // this uses inet_ntop which is documented to only fail if family is not AF_INET or AF_INET6 (or ENOSPC)
            return try! descriptionForAddress(family: .inet6, bytes: &mutAddr, length: Int(INET6_ADDRSTRLEN))
        case .unixDomainSocket(_):
            return nil
        }
    }
    /// Get and set the port associated with the address, if defined.
    /// When setting to `nil` the port will default to `0` for compatible sockets. The rationale for this is that both `nil` and `0` can
    /// be interpreted as "no preference".
    /// Setting a non-nil value for a unix domain socket is invalid and will result in a fatal error.
    public var port: Int? {
        get {
            switch self {
            case .v4(let addr):
                // looks odd but we need to first convert the endianness as `in_port_t` and then make the result an `Int`.
                return Int(in_port_t(bigEndian: addr.address.sin_port))
            case .v6(let addr):
                // looks odd but we need to first convert the endianness as `in_port_t` and then make the result an `Int`.
                return Int(in_port_t(bigEndian: addr.address.sin6_port))
            case .unixDomainSocket:
                return nil
            }
        }
        set {
            switch self {
            case .v4(let addr):
                var mutAddr = addr.address
                mutAddr.sin_port = in_port_t(newValue ?? 0).bigEndian
                self = .v4(.init(address: mutAddr, host: addr.host))
            case .v6(let addr):
                var mutAddr = addr.address
                mutAddr.sin6_port = in_port_t(newValue ?? 0).bigEndian
                self = .v6(.init(address: mutAddr, host: addr.host))
            case .unixDomainSocket:
                precondition(newValue == nil, "attempting to set a non-nil value to a unix socket is not valid")
            }
        }
    }

    /// Get the pathname of a UNIX domain socket as a string
    public var pathname: String? {
        #if os(WASI)
        return nil
        #else
        switch self {
        case .v4:
            return nil
        case .v6:
            return nil
        case .unixDomainSocket(let addr):
            // This is a static assert that exists just to verify the safety of the assumption below.
            assert(Swift.type(of: addr.address.sun_path.0) == CChar.self)
            let pathname: String = withUnsafePointer(to: addr.address.sun_path) { ptr in
                // Homogeneous tuples are always implicitly also bound to their element type, so this assumption below is safe.
                let charPtr = UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                return String(cString: charPtr)
            }
            return pathname
        }
        #endif
    }

    /// Calls the given function with a pointer to a `sockaddr` structure and the associated size
    /// of that structure.
    public func withSockAddr<T>(_ body: (UnsafePointer<sockaddr>, Int) throws -> T) rethrows -> T {
        switch self {
        case .v4(let addr):
            return try addr.address.withSockAddr({ try body($0, $1) })
        case .v6(let addr):
            return try addr.address.withSockAddr({ try body($0, $1) })
        case .unixDomainSocket(let addr):
            return try addr.address.withSockAddr({ try body($0, $1) })
        }
    }

    /// Creates a new IPv4 `SocketAddress`.
    ///
    /// - Parameters:
    ///   - addr: the `sockaddr_in` that holds the ipaddress and port.
    ///   - host: the hostname that resolved to the ipaddress.
    public init(_ addr: sockaddr_in, host: String) {
        self = .v4(.init(address: addr, host: host))
    }

    /// Creates a new IPv6 `SocketAddress`.
    ///
    /// - Parameters:
    ///   - addr: the `sockaddr_in` that holds the ipaddress and port.
    ///   - host: the hostname that resolved to the ipaddress.
    public init(_ addr: sockaddr_in6, host: String) {
        self = .v6(.init(address: addr, host: host))
    }

    /// Creates a new IPv4 `SocketAddress`.
    ///
    /// - Parameters:
    ///   - addr: the `sockaddr_in` that holds the ipaddress and port.
    public init(_ addr: sockaddr_in) {
        self = .v4(.init(address: addr, host: addr.addressDescription()))
    }

    /// Creates a new IPv6 `SocketAddress`.
    ///
    /// - Parameters:
    ///   - addr: the `sockaddr_in` that holds the ipaddress and port.
    public init(_ addr: sockaddr_in6) {
        self = .v6(.init(address: addr, host: addr.addressDescription()))
    }

    /// Creates a new Unix Domain Socket `SocketAddress`.
    ///
    /// - Parameters:
    ///   - addr: the `sockaddr_un` that holds the socket path.
    public init(_ addr: sockaddr_un) {
        self = .unixDomainSocket(.init(address: addr))
    }

    /// Creates a new UDS `SocketAddress`.
    ///
    /// - Parameters:
    ///   - unixDomainSocketPath: the path to use for the `SocketAddress`.
    /// - Throws: may throw `SocketAddressError.unixDomainSocketPathTooLong` if the path is too long.
    public init(unixDomainSocketPath: String) throws {
        guard unixDomainSocketPath.utf8.count <= 103 else {
            throw SocketAddressError.unixDomainSocketPathTooLong
        }

        let pathBytes = unixDomainSocketPath.utf8 + [0]

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(NIOBSDSocket.AddressFamily.unix.rawValue)

        #if !os(WASI)
        pathBytes.withUnsafeBytes { srcBuffer in
            withUnsafeMutableBytes(of: &addr.sun_path) { dstPtr in
                dstPtr.copyMemory(from: srcBuffer)
            }
        }
        #endif

        self = .unixDomainSocket(.init(address: addr))
    }

    /// Create a new `SocketAddress` for an IP address in string form.
    ///
    /// - Parameters:
    ///   - ipAddress: The IP address, in string form.
    ///   - port: The target port.
    /// - Throws: may throw `SocketAddressError.failedToParseIPString` if the IP address cannot be parsed.
    public init(ipAddress: String, port: Int) throws {
        self = try ipAddress.withCString {
            do {
                var ipv4Addr = in_addr()
                try NIOBSDSocket.inet_pton(addressFamily: .inet, addressDescription: $0, address: &ipv4Addr)

                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(NIOBSDSocket.AddressFamily.inet.rawValue)
                addr.sin_port = in_port_t(port).bigEndian
                addr.sin_addr = ipv4Addr

                return .v4(.init(address: addr, host: ""))
            } catch {
                // If `inet_pton` fails as an IPv4 address, we will try as an
                // IPv6 address.
            }

            do {
                var ipv6Addr = in6_addr()
                try NIOBSDSocket.inet_pton(addressFamily: .inet6, addressDescription: $0, address: &ipv6Addr)

                var addr = sockaddr_in6()
                addr.sin6_family = sa_family_t(NIOBSDSocket.AddressFamily.inet6.rawValue)
                addr.sin6_port = in_port_t(port).bigEndian
                addr.sin6_flowinfo = 0
                addr.sin6_addr = ipv6Addr
                addr.sin6_scope_id = 0
                return .v6(.init(address: addr, host: ""))
            } catch {
                // If `inet_pton` fails as an IPv6 address (and has failed as an
                // IPv4 address above), we will throw an error below.
            }

            throw SocketAddressError.failedToParseIPString(ipAddress)
        }
    }

    /// Create a new `SocketAddress` for an IP address in ByteBuffer form.
    ///
    /// - Parameters:
    ///   - packedIPAddress: The IP address, in ByteBuffer form.
    ///   - port: The target port.
    /// - Throws: may throw `SocketAddressError.failedToParseIPByteBuffer` if the IP address cannot be parsed.
    public init(packedIPAddress: ByteBuffer, port: Int) throws {
        let packed = packedIPAddress.readableBytesView

        switch packedIPAddress.readableBytes {
        case 4:
            var ipv4Addr = sockaddr_in()
            ipv4Addr.sin_family = sa_family_t(AF_INET)
            ipv4Addr.sin_port = in_port_t(port).bigEndian
            withUnsafeMutableBytes(of: &ipv4Addr.sin_addr) { $0.copyBytes(from: packed) }
            self = .v4(.init(address: ipv4Addr, host: ""))
        case 16:
            var ipv6Addr = sockaddr_in6()
            ipv6Addr.sin6_family = sa_family_t(AF_INET6)
            ipv6Addr.sin6_port = in_port_t(port).bigEndian
            withUnsafeMutableBytes(of: &ipv6Addr.sin6_addr) { $0.copyBytes(from: packed) }
            self = .v6(.init(address: ipv6Addr, host: ""))
        default:
            throw SocketAddressError.FailedToParseIPByteBuffer(address: packedIPAddress)
        }
    }

    /// Creates a new `SocketAddress` corresponding to the netmask for a subnet prefix.
    ///
    /// As an example, consider the subnet "127.0.0.1/8". The "subnet prefix" is "8", and the corresponding netmask is "255.0.0.0".
    /// This initializer will produce a `SocketAddress` that contains "255.0.0.0".
    ///
    /// - Parameters:
    ///   - prefix: The prefix of the subnet.
    /// - Returns: A `SocketAddress` containing the associated netmask.
    internal init(ipv4MaskForPrefix prefix: Int) {
        precondition((0...32).contains(prefix))

        let packedAddress = (UInt32(0xFFFF_FFFF) << (32 - prefix)).bigEndian
        var ipv4Addr = sockaddr_in()
        ipv4Addr.sin_family = sa_family_t(AF_INET)
        ipv4Addr.sin_port = 0
        withUnsafeMutableBytes(of: &ipv4Addr.sin_addr) { $0.storeBytes(of: packedAddress, as: UInt32.self) }
        self = .v4(.init(address: ipv4Addr, host: ""))
    }

    /// Creates a new `SocketAddress` corresponding to the netmask for a subnet prefix.
    ///
    /// As an example, consider the subnet "fe80::/10". The "subnet prefix" is "10", and the corresponding netmask is "ff30::".
    /// This initializer will produce a `SocketAddress` that contains "ff30::".
    ///
    /// - Parameters:
    ///   - prefix: The prefix of the subnet.
    /// - Returns: A `SocketAddress` containing the associated netmask.
    internal init(ipv6MaskForPrefix prefix: Int) {
        precondition((0...128).contains(prefix))

        // This defends against the possibility of a greater-than-/64 subnet, which would produce a negative shift
        // operand which is absolutely not what we want.
        let highShift = min(prefix, 64)
        let packedAddressHigh = (UInt64(0xFFFF_FFFF_FFFF_FFFF) << (64 - highShift)).bigEndian

        let packedAddressLow = (UInt64(0xFFFF_FFFF_FFFF_FFFF) << (128 - prefix)).bigEndian
        let packedAddress = (packedAddressHigh, packedAddressLow)

        var ipv6Addr = sockaddr_in6()
        ipv6Addr.sin6_family = sa_family_t(AF_INET6)
        ipv6Addr.sin6_port = 0
        withUnsafeMutableBytes(of: &ipv6Addr.sin6_addr) { $0.storeBytes(of: packedAddress, as: (UInt64, UInt64).self) }
        self = .v6(.init(address: ipv6Addr, host: ""))
    }

    /// Creates a new `SocketAddress` for the given host (which will be resolved) and port.
    ///
    /// - warning: This is a blocking call, so please avoid calling this from an `EventLoop`.
    ///
    /// - Parameters:
    ///   - host: the hostname which should be resolved.
    ///   - port: the port itself
    /// - Returns: the `SocketAddress` for the host / port pair.
    /// - Throws: a `SocketAddressError.unknown` if we could not resolve the `host`, or `SocketAddressError.unsupported` if the address itself is not supported (yet).
    public static func makeAddressResolvingHost(_ host: String, port: Int) throws -> SocketAddress {
        #if os(WASI)
        throw SocketAddressError.unsupported
        #endif

        #if os(Windows)
        return try host.withCString(encodedAs: UTF16.self) { wszHost in
            try String(port).withCString(encodedAs: UTF16.self) { wszPort in
                var pResult: UnsafeMutablePointer<ADDRINFOW>?

                let result = GetAddrInfoW(wszHost, wszPort, nil, &pResult)
                guard result == 0 else {
                    throw SocketAddressError.unknown(host: host, port: port)
                }

                defer {
                    FreeAddrInfoW(pResult)
                }

                if let pResult = pResult, let addressBytes = UnsafeRawPointer(pResult.pointee.ai_addr) {
                    switch pResult.pointee.ai_family {
                    case AF_INET:
                        return .v4(IPv4Address(address: addressBytes.load(as: sockaddr_in.self), host: host))
                    case AF_INET6:
                        return .v6(IPv6Address(address: addressBytes.load(as: sockaddr_in6.self), host: host))
                    default:
                        break
                    }
                }

                throw SocketAddressError.unsupported
            }
        }
        #elseif !os(WASI)
        var info: UnsafeMutablePointer<addrinfo>?

        // FIXME: this is blocking!
        if getaddrinfo(host, String(port), nil, &info) != 0 {
            throw SocketAddressError.unknown(host: host, port: port)
        }

        defer {
            if info != nil {
                freeaddrinfo(info)
            }
        }

        if let info = info, let addrPointer = info.pointee.ai_addr {
            let addressBytes = UnsafeRawPointer(addrPointer)
            switch NIOBSDSocket.AddressFamily(rawValue: info.pointee.ai_family) {
            case .inet:
                return .v4(.init(address: addressBytes.load(as: sockaddr_in.self), host: host))
            case .inet6:
                return .v6(.init(address: addressBytes.load(as: sockaddr_in6.self), host: host))
            default:
                throw SocketAddressError.unsupported
            }
        } else {
            // this is odd, getaddrinfo returned NULL
            throw SocketAddressError.unsupported
        }
        #endif
    }
}

/// We define an extension on `SocketAddress` that gives it an elementwise equatable conformance, using
/// only the elements defined on the structure in their man pages (excluding lengths).
extension SocketAddress: Equatable {
    public static func == (lhs: SocketAddress, rhs: SocketAddress) -> Bool {
        switch (lhs, rhs) {
        case (.v4(let addr1), .v4(let addr2)):
            #if os(Windows)
            return addr1.address.sin_family == addr2.address.sin_family
                && addr1.address.sin_port == addr2.address.sin_port
                && addr1.address.sin_addr.S_un.S_addr == addr2.address.sin_addr.S_un.S_addr
            #else
            return addr1.address.sin_family == addr2.address.sin_family
                && addr1.address.sin_port == addr2.address.sin_port
                && addr1.address.sin_addr.s_addr == addr2.address.sin_addr.s_addr
            #endif
        case (.v6(let addr1), .v6(let addr2)):
            guard
                addr1.address.sin6_family == addr2.address.sin6_family
                    && addr1.address.sin6_port == addr2.address.sin6_port
                    && addr1.address.sin6_flowinfo == addr2.address.sin6_flowinfo
                    && addr1.address.sin6_scope_id == addr2.address.sin6_scope_id
            else {
                return false
            }

            var s6addr1 = addr1.address.sin6_addr
            var s6addr2 = addr2.address.sin6_addr
            return memcmp(&s6addr1, &s6addr2, MemoryLayout.size(ofValue: s6addr1)) == 0
        case (.unixDomainSocket(let addr1), .unixDomainSocket(let addr2)):
            guard addr1.address.sun_family == addr2.address.sun_family else {
                return false
            }

            #if os(WASI)
            return true
            #else
            let bufferSize = MemoryLayout.size(ofValue: addr1.address.sun_path)

            // Swift implicitly binds the memory for homogeneous tuples to both the tuple type and the element type.
            // This allows us to use assumingMemoryBound(to:) for managing the types. However, we add a static assertion here to validate
            // that the element type _really is_ what we're assuming it to be.
            assert(Swift.type(of: addr1.address.sun_path.0) == CChar.self)
            assert(Swift.type(of: addr2.address.sun_path.0) == CChar.self)
            return withUnsafePointer(to: addr1.address.sun_path) { sunpath1 in
                withUnsafePointer(to: addr2.address.sun_path) { sunpath2 in
                    let typedSunpath1 = UnsafeRawPointer(sunpath1).assumingMemoryBound(to: CChar.self)
                    let typedSunpath2 = UnsafeRawPointer(sunpath2).assumingMemoryBound(to: CChar.self)
                    return strncmp(typedSunpath1, typedSunpath2, bufferSize) == 0
                }
            }
            #endif
        case (.v4, _), (.v6, _), (.unixDomainSocket, _):
            return false
        }
    }
}

extension SocketAddress.IPv4Address: Sendable {}
extension SocketAddress.IPv6Address: Sendable {}

/// We define an extension on `SocketAddress` that gives it an elementwise hashable conformance, using
/// only the elements defined on the structure in their man pages (excluding lengths).
extension SocketAddress: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .unixDomainSocket(let uds):
            hasher.combine(0)
            hasher.combine(uds.address.sun_family)

            #if !os(WASI)
            let pathSize = MemoryLayout.size(ofValue: uds.address.sun_path)

            // Swift implicitly binds the memory of homogeneous tuples to both the tuple type and the element type.
            // We can therefore use assumingMemoryBound(to:) for pointer type conversion. We add a static assert just to
            // validate that we are actually right about the element type.
            assert(Swift.type(of: uds.address.sun_path.0) == CChar.self)
            withUnsafePointer(to: uds.address.sun_path) { pathPtr in
                let typedPathPointer = UnsafeRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                let length = strnlen(typedPathPointer, pathSize)
                let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(typedPathPointer), count: length)
                hasher.combine(bytes: bytes)
            }
            #endif
        case .v4(let v4Addr):
            hasher.combine(1)
            hasher.combine(v4Addr.address.sin_family)
            hasher.combine(v4Addr.address.sin_port)
            #if os(Windows)
            hasher.combine(v4Addr.address.sin_addr.S_un.S_addr)
            #else
            hasher.combine(v4Addr.address.sin_addr.s_addr)
            #endif
        case .v6(let v6Addr):
            hasher.combine(2)
            hasher.combine(v6Addr.address.sin6_family)
            hasher.combine(v6Addr.address.sin6_port)
            hasher.combine(v6Addr.address.sin6_flowinfo)
            hasher.combine(v6Addr.address.sin6_scope_id)
            withUnsafeBytes(of: v6Addr.address.sin6_addr) {
                hasher.combine(bytes: $0)
            }
        }
    }
}

extension SocketAddress {
    /// Whether this `SocketAddress` corresponds to a multicast address.
    public var isMulticast: Bool {
        switch self {
        case .unixDomainSocket:
            // No multicast on unix sockets.
            return false
        case .v4(let v4Addr):
            // For IPv4 a multicast address is in the range 224.0.0.0/4.
            // The easy way to check if this is the case is to just mask off
            // the address.
            #if os(Windows)
            let v4WireAddress = v4Addr.address.sin_addr.S_un.S_addr
            let mask = UInt32(0xF000_0000).bigEndian
            let subnet = UInt32(0xE000_0000).bigEndian
            #else
            let v4WireAddress = v4Addr.address.sin_addr.s_addr
            let mask = in_addr_t(0xF000_0000 as UInt32).bigEndian
            let subnet = in_addr_t(0xE000_0000 as UInt32).bigEndian
            #endif
            return v4WireAddress & mask == subnet
        case .v6(let v6Addr):
            // For IPv6 a multicast address is in the range ff00::/8.
            // Here we don't need a bitmask, as all the top bits are set,
            // so we can just ask for equality on the top byte.
            var v6WireAddress = v6Addr.address.sin6_addr
            return withUnsafeBytes(of: &v6WireAddress) { $0[0] == 0xff }
        }
    }
}

protocol SockAddrProtocol {
    func withSockAddr<R>(_ body: (UnsafePointer<sockaddr>, Int) throws -> R) rethrows -> R
}

/// Returns a description for the given address.
internal func descriptionForAddress(
    family: NIOBSDSocket.AddressFamily,
    bytes: UnsafeRawPointer,
    length byteCount: Int
) throws -> String {
    var addressBytes: [Int8] = Array(repeating: 0, count: byteCount)
    return try addressBytes.withUnsafeMutableBufferPointer {
        (addressBytesPtr: inout UnsafeMutableBufferPointer<Int8>) -> String in
        try NIOBSDSocket.inet_ntop(
            addressFamily: family,
            addressBytes: bytes,
            addressDescription: addressBytesPtr.baseAddress!,
            addressDescriptionLength: socklen_t(byteCount)
        )
        return addressBytesPtr.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: byteCount) {
            addressBytesPtr -> String in
            String(cString: addressBytesPtr)
        }
    }
}

extension sockaddr_in: SockAddrProtocol {
    func withSockAddr<R>(_ body: (UnsafePointer<sockaddr>, Int) throws -> R) rethrows -> R {
        try withUnsafeBytes(of: self) { p in
            try body(p.baseAddress!.assumingMemoryBound(to: sockaddr.self), p.count)
        }
    }

    /// Returns a description of the `sockaddr_in`.
    func addressDescription() -> String {
        withUnsafePointer(to: self.sin_addr) { addrPtr in
            // this uses inet_ntop which is documented to only fail if family is not AF_INET or AF_INET6 (or ENOSPC)
            try! descriptionForAddress(family: .inet, bytes: addrPtr, length: Int(INET_ADDRSTRLEN))
        }
    }
}

extension sockaddr_in6: SockAddrProtocol {
    func withSockAddr<R>(_ body: (UnsafePointer<sockaddr>, Int) throws -> R) rethrows -> R {
        try withUnsafeBytes(of: self) { p in
            try body(p.baseAddress!.assumingMemoryBound(to: sockaddr.self), p.count)
        }
    }

    /// Returns a description of the `sockaddr_in6`.
    func addressDescription() -> String {
        withUnsafePointer(to: self.sin6_addr) { addrPtr in
            // this uses inet_ntop which is documented to only fail if family is not AF_INET or AF_INET6 (or ENOSPC)
            try! descriptionForAddress(family: .inet6, bytes: addrPtr, length: Int(INET6_ADDRSTRLEN))
        }
    }
}

extension sockaddr_un: SockAddrProtocol {
    func withSockAddr<R>(_ body: (UnsafePointer<sockaddr>, Int) throws -> R) rethrows -> R {
        try withUnsafeBytes(of: self) { p in
            try body(p.baseAddress!.assumingMemoryBound(to: sockaddr.self), p.count)
        }
    }
}

extension sockaddr_storage: SockAddrProtocol {
    func withSockAddr<R>(_ body: (UnsafePointer<sockaddr>, Int) throws -> R) rethrows -> R {
        try withUnsafeBytes(of: self) { p in
            try body(p.baseAddress!.assumingMemoryBound(to: sockaddr.self), p.count)
        }
    }
}

// MARK: Workarounds for SR-14268
// We need these free functions to expose our extension methods, because otherwise
// the compiler falls over when we try to access them from test code. As these functions
// exist purely to make the behaviours accessible from test code, we name them truly awfully.
func __testOnly_addressDescription(_ addr: sockaddr_in) -> String {
    addr.addressDescription()
}

func __testOnly_addressDescription(_ addr: sockaddr_in6) -> String {
    addr.addressDescription()
}

func __testOnly_withSockAddr<ReturnType>(
    _ addr: sockaddr_in,
    _ body: (UnsafePointer<sockaddr>, Int) throws -> ReturnType
) rethrows -> ReturnType {
    try addr.withSockAddr(body)
}

func __testOnly_withSockAddr<ReturnType>(
    _ addr: sockaddr_in6,
    _ body: (UnsafePointer<sockaddr>, Int) throws -> ReturnType
) rethrows -> ReturnType {
    try addr.withSockAddr(body)
}
