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

import Foundation

#if os(Linux)
    import Glibc
    let sysBind = Glibc.bind
    let sysClose = Glibc.close
    let sysSocket = Glibc.socket
    let sysSOCK_STREAM = SOCK_STREAM.rawValue
#else
    import Darwin
    let sysBind = Darwin.bind
    let sysClose = Darwin.close
    let sysSocket = Darwin.socket
    let sysSOCK_STREAM = SOCK_STREAM
#endif

protocol Registration {
    var interested: IOEvent { get set }
}

protocol SockAddrProtocol {
    mutating func withSockAddr<R>(_ fn: (UnsafePointer<sockaddr>, Int) throws -> R) rethrows -> R
}
extension sockaddr_in: SockAddrProtocol {
    mutating func withSockAddr<R>(_ fn: (UnsafePointer<sockaddr>, Int) throws -> R) rethrows -> R {
        var me = self
        return try withUnsafeBytes(of: &me) { p in
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
}

extension sockaddr_un: SockAddrProtocol {
    mutating func withSockAddr<R>(_ fn: (UnsafePointer<sockaddr>, Int) throws -> R) rethrows -> R {
        var me = self
        return try withUnsafeBytes(of: &me) { p in
            try fn(p.baseAddress!.assumingMemoryBound(to: sockaddr.self), p.count)
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
                        return SocketAddress.unixDomainSocket(address: uds.pointee)
                    }
                default:
                    fatalError("address family \(address.pointee.sa_family) not supported")
                }
            })
        }
    }
    static func newSocket(protocolFamily: Int32) throws -> Int32 {
        let sock = try wrapSyscall({ $0 >= 0 }, function: "socket") { () -> Int32 in
            sysSocket(protocolFamily, Int32(sysSOCK_STREAM), 0)
        }
        if protocolFamily == AF_INET6 {
            var zero: Int32 = 0
            do {
                _ = try wrapSyscall({ $0 == 0 }, function: "setsockopt") { () -> Int32 in
                    setsockopt(sock, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &zero, socklen_t(MemoryLayout.size(ofValue: zero)))
                }
            } catch let e as IOError {
                if e.errno != EAFNOSUPPORT {
                    _ = try wrapSyscall({ $0 == 0 }, function: "close") { () -> Int32 in
                        sysClose(sock)
                    }
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
            throw IOError(errno: EBADF, reason: "can't control file descriptor as it's not open anymore.")
        }

        let _ = try wrapSyscall({ $0 >= 0 }, function: "fcntl") {
            fcntl(self.descriptor, F_SETFL, O_NONBLOCK)
        }
    }
    
    final func setOption<T>(level: Int32, name: Int32, value: T) throws {
        guard self.open else {
            throw IOError(errno: EBADF, reason: "can't set socket options as it's not open anymore.")
        }

        var val = value
        
        let _ = try wrapSyscall({ $0 != -1 }, function: "setsockopt") {
            setsockopt(
                self.descriptor,
                level,
                name,
                &val,
                socklen_t(MemoryLayout.size(ofValue: val)))
        }
    }

    final func getOption<T>(level: Int32, name: Int32) throws -> T {
        guard self.open else {
            throw IOError(errno: EBADF, reason: "can't get socket options as it's not open anymore.")
        }

        var length = socklen_t(MemoryLayout<T>.size)
        var val = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer {
            val.deinitialize()
            val.deallocate(capacity: 1)
        }
        
        let _ = try wrapSyscall({ $0 != -1 }, function: "getsockopt") {
            getsockopt(self.descriptor, level, name, val, &length)
        }
        return val.pointee
    }
    
    final func bind(to address: SocketAddress) throws {
        guard self.open else {
            throw IOError(errno: EBADF, reason: "can't bind socket as it's not open anymore.")
        }

        func doBind(ptr: UnsafePointer<sockaddr>, bytes: Int) throws {
            _ = try wrapSyscall({ $0 == 0 }, function: "bind") {
                sysBind(self.descriptor, ptr, socklen_t(bytes))
            }
        }

        switch address {
        case .v4(address: var addr, _):
            try addr.withSockAddr(doBind)
        case .v6(address: var addr, _):
            try addr.withSockAddr(doBind)
        case .unixDomainSocket(address: var addr):
            try addr.withSockAddr(doBind)
        }
    }
    
    final func close() throws {
        guard self.open else {
            throw IOError(errno: EBADF, reason: "can't close socket (as it's not open anymore.")
        }

        let _ = try wrapSyscall({ $0 >= 0 }, function: "close") {
             sysClose(self.descriptor)
        }
        self.open = false
    }
}
