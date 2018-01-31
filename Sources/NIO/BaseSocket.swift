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

protocol Registration {
    var interested: IOEvent { get set }
}

protocol SockAddrProtocol {
    mutating func withSockAddr<R>(_ fn: (UnsafePointer<sockaddr>, Int) throws -> R) rethrows -> R
    mutating func withMutableSockAddr<R>(_ fn: (UnsafeMutablePointer<sockaddr>, Int) throws -> R) rethrows -> R
}

extension sockaddr_in: SockAddrProtocol {
    mutating func withSockAddr<R>(_ fn: (UnsafePointer<sockaddr>, Int) throws -> R) rethrows -> R {
        var me = self
        return try withUnsafeBytes(of: &me) { p in
            try fn(p.baseAddress!.assumingMemoryBound(to: sockaddr.self), p.count)
        }
    }

    mutating func withMutableSockAddr<R>(_ fn: (UnsafeMutablePointer<sockaddr>, Int) throws -> R) rethrows -> R {
        var me = self
        return try withUnsafeMutableBytes(of: &me) { p in
            try fn(p.baseAddress!.assumingMemoryBound(to: sockaddr.self), p.count)
        }
    }
}

extension sockaddr_in6: SockAddrProtocol {
    mutating func withSockAddr<R>(_ fn: (UnsafePointer<sockaddr>, Int) throws -> R) rethrows -> R {
        var me = self
        return try withUnsafeBytes(of: &me) { p in
            try fn(p.baseAddress!.assumingMemoryBound(to: sockaddr.self), p.count)
        }
    }

    mutating func withMutableSockAddr<R>(_ fn: (UnsafeMutablePointer<sockaddr>, Int) throws -> R) rethrows -> R {
        var me = self
        return try withUnsafeMutableBytes(of: &me) { p in
            try fn(p.baseAddress!.assumingMemoryBound(to: sockaddr.self), p.count)
        }
    }
}

extension sockaddr_un: SockAddrProtocol {
    mutating func withSockAddr<R>(_ fn: (UnsafePointer<sockaddr>, Int) throws -> R) rethrows -> R {
        var me = self
        return try withUnsafeBytes(of: &me) { p in
            try fn(p.baseAddress!.assumingMemoryBound(to: sockaddr.self), p.count)
        }
    }

    mutating func withMutableSockAddr<R>(_ fn: (UnsafeMutablePointer<sockaddr>, Int) throws -> R) rethrows -> R {
        var me = self
        return try withUnsafeMutableBytes(of: &me) { p in
            try fn(p.baseAddress!.assumingMemoryBound(to: sockaddr.self), p.count)
        }
    }
}

extension sockaddr_storage: SockAddrProtocol {
    mutating func withSockAddr<R>(_ fn: (UnsafePointer<sockaddr>, Int) throws -> R) rethrows -> R {
        var me = self
        return try withUnsafeBytes(of: &me) { p in
            try fn(p.baseAddress!.assumingMemoryBound(to: sockaddr.self), p.count)
        }
    }

    mutating func withMutableSockAddr<R>(_ fn: (UnsafeMutablePointer<sockaddr>, Int) throws -> R) rethrows -> R {
        var me = self
        return try withUnsafeMutableBytes(of: &me) { p in
            try fn(p.baseAddress!.assumingMemoryBound(to: sockaddr.self), p.count)
        }
    }
}

// sockaddr_storage is basically just a boring data structure that we can
// convert to being something sensible. These functions copy the data as
// needed.
//
// Annoyingly, these functions are mutating. This is required to work around
// https://bugs.swift.org/browse/SR-2749 on Ubuntu 14.04: basically, we need to
// avoid getting the Swift compiler to copy the sockaddr_storage for any reason:
// only our rebinding copy here is allowed.
extension sockaddr_storage {
    mutating func convert() -> sockaddr_in {
        precondition(self.ss_family == AF_INET)
        return withUnsafePointer(to: &self) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee
            }
        }
    }

    mutating func convert() -> sockaddr_in6 {
        precondition(self.ss_family == AF_INET6)
        return withUnsafePointer(to: &self) {
            $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                $0.pointee
            }
        }
    }

    mutating func convert() -> sockaddr_un {
        precondition(self.ss_family == AF_UNIX)
        return withUnsafePointer(to: &self) {
            $0.withMemoryRebound(to: sockaddr_un.self, capacity: 1) {
                $0.pointee
            }
        }
    }
}

class BaseSocket : Selectable {
    public let descriptor: Int32
    public private(set) var open: Bool
    
    final var localAddress: SocketAddress? {
        get {
            return get_addr { getsockname($0, $1, $2) }
        }
    }
    
    final var remoteAddress: SocketAddress? {
        get {
            return get_addr { getpeername($0, $1, $2) }
        }
    }

    private func get_addr(_ fn: (Int32, UnsafeMutablePointer<sockaddr>, UnsafeMutablePointer<socklen_t>) -> Int32) -> SocketAddress? {
        var addr = sockaddr_storage()
        var len: socklen_t = socklen_t(MemoryLayout<sockaddr_storage>.size)
        
        return withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1, { address in
                guard  fn(descriptor, address, &len) == 0 else {
                    return nil
                }
                switch Int32(address.pointee.sa_family) {
                case AF_INET:
                    return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { ipv4 in
                        var ipAddressString = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        return SocketAddress(IPv4Address: ipv4.pointee, host: String(cString: inet_ntop(AF_INET, &ipv4.pointee.sin_addr, &ipAddressString, socklen_t(INET_ADDRSTRLEN))))
                    })
                case AF_INET6:
                    return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1, { ipv6 in
                        var ipAddressString = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                        return SocketAddress(IPv6Address: ipv6.pointee, host: String(cString: inet_ntop(AF_INET6, &ipv6.pointee.sin6_addr, &ipAddressString, socklen_t(INET6_ADDRSTRLEN))))
                    })
                case AF_UNIX:
                    return address.withMemoryRebound(to: sockaddr_un.self, capacity: 1) { uds in
                        return SocketAddress(unixDomainSocket: uds.pointee)
                    }
                default:
                    fatalError("address family \(address.pointee.sa_family) not supported")
                }
            })
        }
    }
    static func newSocket(protocolFamily: Int32) throws -> Int32 {
        let sock = try Posix.socket(domain: protocolFamily,
                                    type: Posix.SOCK_STREAM,
                                    protocol: 0)
        
        if protocolFamily == AF_INET6 {
            var zero: Int32 = 0
            do {
                _ = try Posix.setsockopt(socket: sock, level: Int32(IPPROTO_IPV6), optionName: IPV6_V6ONLY, optionValue: &zero, optionLen: socklen_t(MemoryLayout.size(ofValue: zero)))

            } catch let e as IOError {
                if e.errnoCode != EAFNOSUPPORT {
                    // Ignore error that may be thrown by close.
                    _ = try? Posix.close(descriptor: sock)
                    throw e
                }
                /* we couldn't enable dual IP4/6 support, that's okay too. */
            } catch let e {
                fatalError("Unexpected error type \(e)")
            }
        }
        return sock
    }
    
    // TODO: This needs a way to encourage proper open/close behavior.
    //       A closure a la Ruby's File.open may make sense.
    init(descriptor : Int32) {
        self.descriptor = descriptor
        self.open = true
    }

    final func setNonBlocking() throws {
        guard self.open else {
            throw IOError(errnoCode: EBADF, reason: "can't control file descriptor as it's not open anymore.")
        }

        try Posix.fcntl(descriptor: descriptor, command: F_SETFL, value: O_NONBLOCK)
    }
    
    final func setOption<T>(level: Int32, name: Int32, value: T) throws {
        guard self.open else {
            throw IOError(errnoCode: EBADF, reason: "can't set socket options as it's not open anymore.")
        }

        var val = value
        
        let _ = try Posix.setsockopt(
            socket: self.descriptor,
            level: level,
            optionName: name,
            optionValue: &val,
            optionLen: socklen_t(MemoryLayout.size(ofValue: val)))
    }

    final func getOption<T>(level: Int32, name: Int32) throws -> T {
        guard self.open else {
            throw IOError(errnoCode: EBADF, reason: "can't get socket options as it's not open anymore.")
        }

        var length = socklen_t(MemoryLayout<T>.size)
        var val = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer {
            val.deinitialize(count: 1)
            val.deallocate()
        }
        
        try Posix.getsockopt(socket: self.descriptor, level: level, optionName: name, optionValue: val, optionLen: &length)
        return val.pointee
    }
    
    final func bind(to address: SocketAddress) throws {
        guard self.open else {
            throw IOError(errnoCode: EBADF, reason: "can't bind socket as it's not open anymore.")
        }

        func doBind(ptr: UnsafePointer<sockaddr>, bytes: Int) throws {
           try Posix.bind(descriptor: self.descriptor, ptr: ptr, bytes: bytes)
        }

        switch address {
        case .v4(let address):
            var addr = address.address
            try addr.withSockAddr(doBind)
        case .v6(let address):
            var addr = address.address
            try addr.withSockAddr(doBind)
        case .unixDomainSocket(let address):
            var addr = address.address
            try addr.withSockAddr(doBind)
        }
    }
    
    final func close() throws {
        guard self.open else {
            throw IOError(errnoCode: EBADF, reason: "can't close socket (as it's not open anymore.")
        }

        try Posix.close(descriptor: self.descriptor)

        self.open = false
    }
}
