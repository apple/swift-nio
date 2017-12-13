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

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    import Darwin
#elseif os(Linux)
    import Glibc
#endif

/// Special `Error` that may be thrown if we fail to create a `SocketAddress`.
public enum SocketAddressError: Error {
    /// The host is unknown (could not be resolved).
    case unknown(host: String, port: Int32)
    /// The requested `SocketAddress` is not supported.
    case unsupported
    /// The requested UDS path is too long.
    case unixDomainSocketPathTooLong
}

/// Represent a socket address to which we may want to connect or bind.
public enum SocketAddress: CustomStringConvertible {
    case v4(address: sockaddr_in, host: String)
    case v6(address: sockaddr_in6, host: String)
    case unixDomainSocket(address: sockaddr_un)

    /// A human-readable description of this `SocketAddress`. Mostly useful for logging.
    public var description: String {
        let port: String
        let host: String?
        let type: String
        switch self {
        case .v4(address: let addr, host: let h):
            host = h
            type = "IPv4"
            port = "\(UInt16(bigEndian: addr.sin_port))"
        case .v6(address: let addr, host: let h):
            host = h
            type = "IPv6"
            port = "\(UInt16(bigEndian: addr.sin6_port))"
        case .unixDomainSocket(address: var addr):
            host = nil
            type = "UDS"
            port = withUnsafeBytes(of: &addr.sun_path) { ptr in
                let ptr = ptr.baseAddress!.bindMemory(to: UInt8.self, capacity: 104)
                return String(cString: ptr)
            }
        }
        return "[\(type)]\(host.map { "\($0):" } ?? "")\(port)"
    }
    
    /// Returns the protocol family as defined in `man 2 socket` of this `SocketAddress`.
    public var protocolFamily: Int32 {
        switch self {
        case .v4(address: _, host: _):
            return PF_INET
        case .v6(address: _, host: _):
            return PF_INET6
        case .unixDomainSocket(address: _):
            return PF_UNIX
        }
    }

    /// Creates a new IPV4 `SocketAddress`.
    ///
    /// - parameters:
    ///       - addr: the `sockaddr_in` that holds the ipaddress and port.
    ///       - host: the hostname that resolved to the ipaddress.
    public init(IPv4Address addr: sockaddr_in, host: String) {
        self = .v4(address: addr, host: host)
    }

    /// Creates a new IPV6 `SocketAddress`.
    ///
    /// - parameters:
    ///       - addr: the `sockaddr_in` that holds the ipaddress and port.
    ///       - host: the hostname that resolved to the ipaddress.
    public init(IPv6Address addr: sockaddr_in6, host: String) {
        self = .v6(address: addr, host: host)
    }

    /// Creates a new UDS `SocketAddress`.
    ///
    /// - parameters:
    ///     - path: the path to use for the `SocketAddress`.
    /// - returns: the `SocketAddress` for the given path.
    /// - throws: may throw `SocketAddressError.unixDomainSocketPathTooLong` if the path is too long.
    public static func unixDomainSocketAddress(path: String) throws -> SocketAddress {
        guard path.utf8.count <= 103 else {
            throw SocketAddressError.unixDomainSocketPathTooLong
        }

        let pathBytes = path.utf8 + [0]

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        pathBytes.withUnsafeBufferPointer { srcPtr in
            withUnsafeMutablePointer(to: &addr.sun_path) { dstPtr in
                dstPtr.withMemoryRebound(to: UInt8.self, capacity: pathBytes.count) { dstPtr in
                    dstPtr.assign(from: srcPtr.baseAddress!, count: pathBytes.count)
                }
            }
        }

        return .unixDomainSocket(address: addr)
    }

    /// Creates a new `SocketAddress` for the given host (which will be resolved) and port.
    ///
    /// - parameters:
    ///       - host: the hostname which should be resolved.
    ///       - port: the port itself
    /// - returns: the `SocketAddress` for the host / port pair.
    /// - throws: a `SocketAddressError.unknown` if we could not resolve the `host`, or `SocketAddressError.unsupported` if the address itself is not supported (yet).
    public static func newAddressResolving(host: String, port: Int32) throws -> SocketAddress {
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
                    return .v4(address: ptr.pointee, host: host)
                }
            case AF_INET6:
                return info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { ptr in
                    return .v6(address: ptr.pointee, host: host)
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

