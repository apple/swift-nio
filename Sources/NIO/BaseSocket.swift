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

/// A Registration on a `Selector`, which is interested in an `SelectorEventSet`.
protocol Registration {
    /// The `SelectorEventSet` in which the `Registration` is interested.
    var interested: SelectorEventSet { get set }
}

protocol SockAddrProtocol {
    mutating func withSockAddr<R>(_ body: (UnsafePointer<sockaddr>, Int) throws -> R) rethrows -> R
    mutating func withMutableSockAddr<R>(_ body: (UnsafeMutablePointer<sockaddr>, Int) throws -> R) rethrows -> R
}

/// Returns a description for the given address.
private func descriptionForAddress(family: CInt, bytes: UnsafeRawPointer, length byteCount: Int) -> String {
    var addressBytes: [Int8] = Array(repeating: 0, count: byteCount)
    return addressBytes.withUnsafeMutableBufferPointer { (addressBytesPtr: inout UnsafeMutableBufferPointer<Int8>) -> String in
        try! Posix.inet_ntop(addressFamily: family,
                             addressBytes: bytes,
                             addressDescription: addressBytesPtr.baseAddress!,
                             addressDescriptionLength: socklen_t(byteCount))
        return addressBytesPtr.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: byteCount) { addressBytesPtr -> String in
            String(cString: addressBytesPtr)
        }
    }
}

/// A helper extension for working with sockaddr pointers.
extension UnsafeMutablePointer where Pointee == sockaddr {
    /// Converts the `sockaddr` to a `SocketAddress`.
    func convert() -> SocketAddress? {
        switch pointee.sa_family {
        case Posix.AF_INET:
            return self.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                SocketAddress($0.pointee, host: $0.pointee.addressDescription())
            }
        case Posix.AF_INET6:
            return self.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                SocketAddress($0.pointee, host: $0.pointee.addressDescription())
            }
        case Posix.AF_UNIX:
            return self.withMemoryRebound(to: sockaddr_un.self, capacity: 1) {
                SocketAddress($0.pointee)
            }
        default:
            return nil
        }
    }
}

extension sockaddr_in: SockAddrProtocol {
    mutating func withSockAddr<R>(_ body: (UnsafePointer<sockaddr>, Int) throws -> R) rethrows -> R {
        var me = self
        return try withUnsafeBytes(of: &me) { p in
            try body(p.baseAddress!.assumingMemoryBound(to: sockaddr.self), p.count)
        }
    }

    mutating func withMutableSockAddr<R>(_ body: (UnsafeMutablePointer<sockaddr>, Int) throws -> R) rethrows -> R {
        var me = self
        return try withUnsafeMutableBytes(of: &me) { p in
            try body(p.baseAddress!.assumingMemoryBound(to: sockaddr.self), p.count)
        }
    }

    /// Returns a description of the `sockaddr_in`.
    mutating func addressDescription() -> String {
        return withUnsafePointer(to: &self.sin_addr) { addrPtr in
            descriptionForAddress(family: AF_INET, bytes: addrPtr, length: Int(INET_ADDRSTRLEN))
        }
    }
}

extension sockaddr_in6: SockAddrProtocol {
    mutating func withSockAddr<R>(_ body: (UnsafePointer<sockaddr>, Int) throws -> R) rethrows -> R {
        var me = self
        return try withUnsafeBytes(of: &me) { p in
            try body(p.baseAddress!.assumingMemoryBound(to: sockaddr.self), p.count)
        }
    }

    mutating func withMutableSockAddr<R>(_ body: (UnsafeMutablePointer<sockaddr>, Int) throws -> R) rethrows -> R {
        var me = self
        return try withUnsafeMutableBytes(of: &me) { p in
            try body(p.baseAddress!.assumingMemoryBound(to: sockaddr.self), p.count)
        }
    }

    /// Returns a description of the `sockaddr_in6`.
    mutating func addressDescription() -> String {
        return withUnsafePointer(to: &self.sin6_addr) { addrPtr in
            descriptionForAddress(family: AF_INET6, bytes: addrPtr, length: Int(INET6_ADDRSTRLEN))
        }
    }
}

extension sockaddr_un: SockAddrProtocol {
    mutating func withSockAddr<R>(_ body: (UnsafePointer<sockaddr>, Int) throws -> R) rethrows -> R {
        var me = self
        return try withUnsafeBytes(of: &me) { p in
            try body(p.baseAddress!.assumingMemoryBound(to: sockaddr.self), p.count)
        }
    }

    mutating func withMutableSockAddr<R>(_ body: (UnsafeMutablePointer<sockaddr>, Int) throws -> R) rethrows -> R {
        var me = self
        return try withUnsafeMutableBytes(of: &me) { p in
            try body(p.baseAddress!.assumingMemoryBound(to: sockaddr.self), p.count)
        }
    }
}

extension sockaddr_storage: SockAddrProtocol {
    mutating func withSockAddr<R>(_ body: (UnsafePointer<sockaddr>, Int) throws -> R) rethrows -> R {
        var me = self
        return try withUnsafeBytes(of: &me) { p in
            try body(p.baseAddress!.assumingMemoryBound(to: sockaddr.self), p.count)
        }
    }

    mutating func withMutableSockAddr<R>(_ body: (UnsafeMutablePointer<sockaddr>, Int) throws -> R) rethrows -> R {
        return try withUnsafeMutableBytes(of: &self) { p in
            try body(p.baseAddress!.assumingMemoryBound(to: sockaddr.self), p.count)
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
    /// Converts the `socketaddr_storage` to a `sockaddr_in`.
    ///
    /// This will crash if `ss_family` != AF_INET!
    mutating func convert() -> sockaddr_in {
        precondition(self.ss_family == AF_INET)
        return withUnsafePointer(to: &self) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee
            }
        }
    }

    /// Converts the `socketaddr_storage` to a `sockaddr_in6`.
    ///
    /// This will crash if `ss_family` != AF_INET6!
    mutating func convert() -> sockaddr_in6 {
        precondition(self.ss_family == AF_INET6)
        return withUnsafePointer(to: &self) {
            $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                $0.pointee
            }
        }
    }

    /// Converts the `socketaddr_storage` to a `sockaddr_un`.
    ///
    /// This will crash if `ss_family` != AF_UNIX!
    mutating func convert() -> sockaddr_un {
        precondition(self.ss_family == AF_UNIX)
        return withUnsafePointer(to: &self) {
            $0.withMemoryRebound(to: sockaddr_un.self, capacity: 1) {
                $0.pointee
            }
        }
    }

    /// Converts the `socketaddr_storage` to a `SocketAddress`.
    mutating func convert() -> SocketAddress {
        switch self.ss_family {
        case Posix.AF_INET:
            var sockAddr: sockaddr_in = self.convert()
            return SocketAddress(sockAddr, host: sockAddr.addressDescription())
        case Posix.AF_INET6:
            var sockAddr: sockaddr_in6 = self.convert()
            return SocketAddress(sockAddr, host: sockAddr.addressDescription())
        case Posix.AF_UNIX:
            return SocketAddress(self.convert() as sockaddr_un)
        default:
            fatalError("unknown sockaddr family \(self.ss_family)")
        }
    }
}

/// Base class for sockets.
///
/// This should not be created directly but one of its sub-classes should be used, like `ServerSocket` or `Socket`.
class BaseSocket: Selectable {

    private var descriptor: CInt
    public var isOpen: Bool {
        return descriptor >= 0
    }

    func withUnsafeFileDescriptor<T>(_ body: (CInt) throws -> T) throws -> T {
        guard self.isOpen else {
            throw IOError(errnoCode: EBADF, reason: "file descriptor already closed!")
        }
        return try body(descriptor)
    }

    /// Returns the local bound `SocketAddress` of the socket.
    ///
    /// - returns: The local bound address.
    /// - throws: An `IOError` if the retrieval of the address failed.
    final func localAddress() throws -> SocketAddress {
        return try get_addr { try Posix.getsockname(socket: $0, address: $1, addressLength: $2) }
    }

    /// Returns the connected `SocketAddress` of the socket.
    ///
    /// - returns: The connected address.
    /// - throws: An `IOError` if the retrieval of the address failed.
    final func remoteAddress() throws -> SocketAddress {
        return try get_addr { try Posix.getpeername(socket: $0, address: $1, addressLength: $2) }
    }

    /// Internal helper function for retrieval of a `SocketAddress`.
    private func get_addr(_ body: (Int32, UnsafeMutablePointer<sockaddr>, UnsafeMutablePointer<socklen_t>) throws -> Void) throws -> SocketAddress {
        var addr = sockaddr_storage()

        try addr.withMutableSockAddr { addressPtr, size in
            var size = socklen_t(size)

            try withUnsafeFileDescriptor { fd in
                try body(fd, addressPtr, &size)
            }
        }
        return addr.convert()
    }

    /// Create a new socket and return the file descriptor of it.
    ///
    /// - parameters:
    ///     - protocolFamily: The protocol family to use (usually `AF_INET6` or `AF_INET`).
    ///     - type: The type of the socket to create.
    ///     - setNonBlocking: Set non-blocking mode on the socket.
    /// - returns: the file descriptor of the socket that was created.
    /// - throws: An `IOError` if creation of the socket failed.
    static func newSocket(protocolFamily: Int32, type: CInt, setNonBlocking: Bool = false) throws -> Int32 {
        var sockType = type
        #if os(Linux)
        if setNonBlocking {
            sockType = type | Linux.SOCK_NONBLOCK
        }
        #endif
        let sock = try Posix.socket(domain: protocolFamily,
                                    type: sockType,
                                    protocol: 0)
        #if !os(Linux)
        if setNonBlocking {
            do {
                let ret = try Posix.fcntl(descriptor: sock, command: F_SETFL, value: O_NONBLOCK)
                assert(ret == 0, "unexpectedly, fcntl(\(sock), F_SETFL, O_NONBLOCK) returned \(ret)")
            } catch {
                _ = try? Posix.close(descriptor: sock)
                throw error
            }
        }
        #endif
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

    /// Create a new instance.
    ///
    /// The ownership of the passed in descriptor is transferred to this class. A user must call `close` to close the underlying
    /// file descriptor once it's not needed / used anymore.
    ///
    /// - parameters:
    ///     - descriptor: The file descriptor to wrap.
    init(descriptor: CInt) {
        precondition(descriptor >= 0, "invalid file descriptor")
        self.descriptor = descriptor
    }

    deinit {
        assert(!self.isOpen, "leak of open BaseSocket")
    }

    /// Set the socket as non-blocking.
    ///
    /// All I/O operations will not block and so may return before the actual action could be completed.
    ///
    /// throws: An `IOError` if the operation failed.
    final func setNonBlocking() throws {
        return try withUnsafeFileDescriptor { fd in
            let ret = try Posix.fcntl(descriptor: fd, command: F_SETFL, value: O_NONBLOCK)
            assert(ret == 0, "unexpectedly, fcntl(\(fd), F_SETFL, O_NONBLOCK) returned \(ret)")
        }
    }

    /// Set the given socket option.
    ///
    /// This basically just delegates to `setsockopt` syscall.
    ///
    /// - parameters:
    ///     - level: The protocol level (see `man setsockopt`).
    ///     - name: The name of the option to set.
    ///     - value: The value for the option.
    /// - throws: An `IOError` if the operation failed.
    final func setOption<T>(level: Int32, name: Int32, value: T) throws {
        try withUnsafeFileDescriptor { fd in
            var val = value

            _ = try Posix.setsockopt(
                socket: fd,
                level: level,
                optionName: name,
                optionValue: &val,
                optionLen: socklen_t(MemoryLayout.size(ofValue: val)))
        }
    }

    /// Get the given socket option value.
    ///
    /// This basically just delegates to `getsockopt` syscall.
    ///
    /// - parameters:
    ///     - level: The protocol level (see `man getsockopt`).
    ///     - name: The name of the option to set.
    /// - throws: An `IOError` if the operation failed.
    final func getOption<T>(level: Int32, name: Int32) throws -> T {
        return try withUnsafeFileDescriptor { fd in
            var length = socklen_t(MemoryLayout<T>.size)
            var val = UnsafeMutablePointer<T>.allocate(capacity: 1)
            defer {
                val.deinitialize(count: 1)
                val.deallocate()
            }

            try Posix.getsockopt(socket: fd, level: level, optionName: name, optionValue: val, optionLen: &length)
            return val.pointee
        }
    }

    /// Bind the socket to the given `SocketAddress`.
    ///
    /// - parameters:
    ///     - address: The `SocketAddress` to which the socket should be bound.
    /// - throws: An `IOError` if the operation failed.
    final func bind(to address: SocketAddress) throws {
        try withUnsafeFileDescriptor { fd in
            func doBind(ptr: UnsafePointer<sockaddr>, bytes: Int) throws {
                try Posix.bind(descriptor: fd, ptr: ptr, bytes: bytes)
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
    }

    /// Close the socket.
    ///
    /// After the socket was closed all other methods will throw an `IOError` when called.
    ///
    /// - throws: An `IOError` if the operation failed.
    func close() throws {
        try withUnsafeFileDescriptor { fd in
            try Posix.close(descriptor: fd)
        }

        self.descriptor = -1
    }
}

extension BaseSocket: CustomStringConvertible {
    var description: String {
        return "BaseSocket { fd=\(self.descriptor) } "
    }
}
