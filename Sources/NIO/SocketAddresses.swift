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

/// Special `Error` that may be thrown if we fail to create a `SocketAddress`.
public enum SocketAddressError: Error {
    /// The host is unknown (could not be resolved).
    case unknown(host: String, port: Int)
    /// The requested `SocketAddress` is not supported.
    case unsupported
    /// The requested UDS path is too long.
    case unixDomainSocketPathTooLong
    /// Unable to parse a given IP string
    case failedToParseIPString(String)
}

/// Represent a socket address to which we may want to connect or bind.
public enum SocketAddress: CustomStringConvertible {

    /// A single IPv4 address for `SocketAddress`.
    public struct IPv4Address {
        private let _storage: Box<(address: sockaddr_in, host: String)>

        /// The libc socket address for an IPv4 address.
        public var address: sockaddr_in { return _storage.value.address }

        /// The host this address is for, if known.
        public var host: String { return _storage.value.host }

        fileprivate init(address: sockaddr_in, host: String) {
            self._storage = Box((address: address, host: host))
        }
    }

    /// A single IPv6 address for `SocketAddress`.
    public struct IPv6Address {
        private let _storage: Box<(address: sockaddr_in6, host: String)>

        /// The libc socket address for an IPv6 address.
        public var address: sockaddr_in6 { return _storage.value.address }

        /// The host this address is for, if known.
        public var host: String { return _storage.value.host }

        fileprivate init(address: sockaddr_in6, host: String) {
            self._storage = Box((address: address, host: host))
        }
    }

    /// A single Unix socket address for `SocketAddress`.
    public struct UnixSocketAddress {
        private let _storage: Box<sockaddr_un>

        /// The libc socket address for a Unix Domain Socket.
        public var address: sockaddr_un { return _storage.value }

        fileprivate init(address: sockaddr_un) {
            self._storage = Box(address)
        }
    }

    case v4(IPv4Address)
    case v6(IPv6Address)
    case unixDomainSocket(UnixSocketAddress)

    /// A human-readable description of this `SocketAddress`. Mostly useful for logging.
    public var description: String {
        let port: String
        let host: String?
        let type: String
        switch self {
        case .v4(let addr):
            host = addr.host
            type = "IPv4"
            port = "\(self.port!)"
        case .v6(let addr):
            host = addr.host
            type = "IPv6"
            port = "\(self.port!)"
        case .unixDomainSocket(let addr):
            var address = addr.address
            host = nil
            type = "UDS"
            port = withUnsafeBytes(of: &address.sun_path) { ptr in
                let ptr = ptr.baseAddress!.bindMemory(to: UInt8.self, capacity: 104)
                return String(cString: ptr)
            }
        }
        return "[\(type)]\(host.map { "\($0):" } ?? "")\(port)"
    }

    /// Returns the protocol family as defined in `man 2 socket` of this `SocketAddress`.
    public var protocolFamily: Int32 {
        switch self {
        case .v4:
            return PF_INET
        case .v6:
            return PF_INET6
        case .unixDomainSocket:
            return PF_UNIX
        }
    }

    /// Get the port associated with the address, if defined.
    public var port: UInt16? {
        switch self {
        case .v4(let addr):
            return UInt16(bigEndian: addr.address.sin_port)
        case .v6(let addr):
            return UInt16(bigEndian: addr.address.sin6_port)
        case .unixDomainSocket:
            return nil
        }
    }

    /// Calls the given function with a pointer to a `sockaddr` structure and the associated size
    /// of that structure.
    public func withSockAddr<T>(_ body: (UnsafePointer<sockaddr>, Int) throws -> T) rethrows -> T {
        switch self {
        case .v4(let addr):
            var address = addr.address
            return try address.withSockAddr(body)
        case .v6(let addr):
            var address = addr.address
            return try address.withSockAddr(body)
        case .unixDomainSocket(let addr):
            var address = addr.address
            return try address.withSockAddr(body)
        }
    }

    /// Creates a new IPv4 `SocketAddress`.
    ///
    /// - parameters:
    ///       - addr: the `sockaddr_in` that holds the ipaddress and port.
    ///       - host: the hostname that resolved to the ipaddress.
    public init(_ addr: sockaddr_in, host: String) {
        self = .v4(.init(address: addr, host: host))
    }

    /// Creates a new IPv6 `SocketAddress`.
    ///
    /// - parameters:
    ///       - addr: the `sockaddr_in` that holds the ipaddress and port.
    ///       - host: the hostname that resolved to the ipaddress.
    public init(_ addr: sockaddr_in6, host: String) {
        self = .v6(.init(address: addr, host: host))
    }

    /// Creates a new Unix Domain Socket `SocketAddress`.
    ///
    /// - parameters:
    ///       - addr: the `sockaddr_un` that holds the socket path.
    public init(_ addr: sockaddr_un) {
        self = .unixDomainSocket(.init(address: addr))
    }

    /// Creates a new UDS `SocketAddress`.
    ///
    /// - parameters:
    ///     - path: the path to use for the `SocketAddress`.
    /// - returns: the `SocketAddress` for the given path.
    /// - throws: may throw `SocketAddressError.unixDomainSocketPathTooLong` if the path is too long.
    public init(unixDomainSocketPath: String) throws {
        guard unixDomainSocketPath.utf8.count <= 103 else {
            throw SocketAddressError.unixDomainSocketPathTooLong
        }

        let pathBytes = unixDomainSocketPath.utf8 + [0]

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        pathBytes.withUnsafeBufferPointer { srcPtr in
            withUnsafeMutablePointer(to: &addr.sun_path) { dstPtr in
                dstPtr.withMemoryRebound(to: UInt8.self, capacity: pathBytes.count) { dstPtr in
                    dstPtr.assign(from: srcPtr.baseAddress!, count: pathBytes.count)
                }
            }
        }

        self = .unixDomainSocket(.init(address: addr))
    }

    /// Create a new `SocketAddress` for an IP address in string form.
    ///
    /// - parameters:
    ///     - string: The IP address, in string form.
    ///     - port: The target port.
    /// - returns: the `SocketAddress` corresponding to this string and port combination.
    /// - throws: may throw `SocketAddressError.failedToParseIPString` if the IP address cannot be parsed.
    public init(ipAddress: String, port: UInt16) throws {
        var ipv4Addr = in_addr()
        var ipv6Addr = in6_addr()

        self = try ipAddress.withCString {
            if inet_pton(AF_INET, $0, &ipv4Addr) == 1 {
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                addr.sin_addr = ipv4Addr
                return .v4(.init(address: addr, host: ""))
            } else if inet_pton(AF_INET6, $0, &ipv6Addr) == 1 {
                var addr = sockaddr_in6()
                addr.sin6_family = sa_family_t(AF_INET6)
                addr.sin6_port = port.bigEndian
                addr.sin6_flowinfo = 0
                addr.sin6_addr = ipv6Addr
                addr.sin6_scope_id = 0
                return .v6(.init(address: addr, host: ""))
            } else {
                throw SocketAddressError.failedToParseIPString(ipAddress)
            }
        }
    }

    /// Creates a new `SocketAddress` for the given host (which will be resolved) and port.
    ///
    /// - parameters:
    ///       - host: the hostname which should be resolved.
    ///       - port: the port itself
    /// - returns: the `SocketAddress` for the host / port pair.
    /// - throws: a `SocketAddressError.unknown` if we could not resolve the `host`, or `SocketAddressError.unsupported` if the address itself is not supported (yet).
    public static func newAddressResolving(host: String, port: Int) throws -> SocketAddress {
        var info: UnsafeMutablePointer<addrinfo>?

        /* FIXME: this is blocking! */
        if getaddrinfo(host, String(port), nil, &info) != 0 {
            throw SocketAddressError.unknown(host: host, port: port)
        }

        defer {
            if info != nil {
                freeaddrinfo(info)
            }
        }

        if let info = info {
            switch info.pointee.ai_family {
            case AF_INET:
                return info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ptr in
                    .v4(.init(address: ptr.pointee, host: host))
                }
            case AF_INET6:
                return info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { ptr in
                    .v6(.init(address: ptr.pointee, host: host))
                }
            default:
                throw SocketAddressError.unsupported
            }
        } else {
            /* this is odd, getaddrinfo returned NULL */
            throw SocketAddressError.unsupported
        }
    }
}

/// We define an extension on `SocketAddress` that gives it an elementwise equatable conformance, using
/// only the elements defined on the structure in their man pages (excluding lengths).
extension SocketAddress: Equatable {
    public static func ==(lhs: SocketAddress, rhs: SocketAddress) -> Bool {
        switch (lhs, rhs) {
        case (.v4(let addr1), .v4(let addr2)):
            return addr1.address.sin_family == addr2.address.sin_family &&
                   addr1.address.sin_port == addr2.address.sin_port &&
                   addr1.address.sin_addr.s_addr == addr2.address.sin_addr.s_addr
        case (.v6(let addr1), .v6(let addr2)):
            guard addr1.address.sin6_family == addr2.address.sin6_family &&
                  addr1.address.sin6_port == addr2.address.sin6_port &&
                  addr1.address.sin6_flowinfo == addr2.address.sin6_flowinfo &&
                  addr1.address.sin6_scope_id == addr2.address.sin6_scope_id else {
                    return false
            }

            var s6addr1 = addr1.address.sin6_addr
            var s6addr2 = addr2.address.sin6_addr
            return memcmp(&s6addr1, &s6addr2, MemoryLayout.size(ofValue: s6addr1)) == 0
        case (.unixDomainSocket(let addr1), .unixDomainSocket(let addr2)):
            guard addr1.address.sun_family == addr2.address.sun_family else {
                return false
            }

            var sunpath1 = addr1.address.sun_path
            var sunpath2 = addr2.address.sun_path
            return memcmp(&sunpath1, &sunpath2, MemoryLayout.size(ofValue: sunpath1)) == 0
        case (.v4, _), (.v6, _), (.unixDomainSocket, _):
            return false
        }
    }
}

