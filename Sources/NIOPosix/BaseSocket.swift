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

import NIOCore
import NIOConcurrencyHelpers

#if os(Windows)
import let WinSDK.EAFNOSUPPORT
import let WinSDK.EBADF
import let WinSDK.ENOENT

import let WinSDK.FILE_ATTRIBUTE_REPARSE_POINT
import let WinSDK.FILE_FLAG_BACKUP_SEMANTICS
import let WinSDK.FILE_FLAG_OPEN_REPARSE_POINT
import let WinSDK.FILE_SHARE_DELETE
import let WinSDK.FILE_SHARE_READ
import let WinSDK.FILE_SHARE_WRITE
import let WinSDK.FileDispositionInfoEx

import let WinSDK.GENERIC_READ

import let WinSDK.INET_ADDRSTRLEN
import let WinSDK.INET6_ADDRSTRLEN

import let WinSDK.INVALID_HANDLE_VALUE
import let WinSDK.INVALID_SOCKET

import let WinSDK.IO_REPARSE_TAG_AF_UNIX

import let WinSDK.NO_ERROR

import let WinSDK.OPEN_EXISTING

import func WinSDK.CloseHandle
import func WinSDK.CreateFileW
import func WinSDK.DeviceIoControl
import func WinSDK.GetFileInformationByHandle
import func WinSDK.GetFileType
import func WinSDK.GetLastError
import func WinSDK.SetFileInformationByHandle

import struct WinSDK.BY_HANDLE_FILE_INFORMATION
import struct WinSDK.DWORD
import struct WinSDK.FILE_DISPOSITION_INFO
import struct WinSDK.socklen_t

import CNIOWindows
#endif

protocol Registration {
    /// The `SelectorEventSet` in which the `Registration` is interested.
    var interested: SelectorEventSet { get set }
    var registrationID: SelectorRegistrationID { get set }
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
    mutating func withMutableSockAddr<R>(_ body: (UnsafeMutablePointer<sockaddr>, Int) throws -> R) rethrows -> R {
        return try withUnsafeMutableBytes(of: &self) { p in
            try body(p.baseAddress!.assumingMemoryBound(to: sockaddr.self), p.count)
        }
    }

    /// Converts the `socketaddr_storage` to a `sockaddr_in`.
    ///
    /// This will crash if `ss_family` != AF_INET!
    func convert() -> sockaddr_in {
        precondition(self.ss_family == NIOBSDSocket.AddressFamily.inet.rawValue)
        return withUnsafeBytes(of: self) {
            $0.load(as: sockaddr_in.self)
        }
    }

    /// Converts the `socketaddr_storage` to a `sockaddr_in6`.
    ///
    /// This will crash if `ss_family` != AF_INET6!
    func convert() -> sockaddr_in6 {
        precondition(self.ss_family == NIOBSDSocket.AddressFamily.inet6.rawValue)
        return withUnsafeBytes(of: self) {
            $0.load(as: sockaddr_in6.self)
        }
    }

    /// Converts the `socketaddr_storage` to a `sockaddr_un`.
    ///
    /// This will crash if `ss_family` != AF_UNIX!
    func convert() -> sockaddr_un {
        precondition(self.ss_family == NIOBSDSocket.AddressFamily.unix.rawValue)
        return withUnsafeBytes(of: self) {
            $0.load(as: sockaddr_un.self)
        }
    }

    /// Converts the `socketaddr_storage` to a `SocketAddress`.
    func convert() -> SocketAddress {
        switch NIOBSDSocket.AddressFamily(rawValue: CInt(self.ss_family)) {
        case .inet:
            let sockAddr: sockaddr_in = self.convert()
            return SocketAddress(sockAddr)
        case .inet6:
            let sockAddr: sockaddr_in6 = self.convert()
            return SocketAddress(sockAddr)
        case .unix:
            return SocketAddress(self.convert() as sockaddr_un)
        default:
            fatalError("unknown sockaddr family \(self.ss_family)")
        }
    }
}

/// A helper extension for working with sockaddr pointers.
extension UnsafeMutablePointer where Pointee == sockaddr {
    /// Converts the `sockaddr` to a `SocketAddress`.
    func convert() -> SocketAddress? {
        let addressBytes = UnsafeRawPointer(self)
        switch NIOBSDSocket.AddressFamily(rawValue: CInt(pointee.sa_family)) {
        case .inet:
            return SocketAddress(addressBytes.load(as: sockaddr_in.self))
        case .inet6:
            return SocketAddress(addressBytes.load(as: sockaddr_in6.self))
        case .unix:
            return SocketAddress(addressBytes.load(as: sockaddr_un.self))
        default:
            return nil
        }
    }
}

/// Base class for sockets.
///
/// This should not be created directly but one of its sub-classes should be used, like `ServerSocket` or `Socket`.
class BaseSocket: BaseSocketProtocol {
    typealias SelectableType = BaseSocket

    private var descriptor: NIOBSDSocket.Handle
    public var isOpen: Bool {
        #if os(Windows)
            return descriptor != NIOBSDSocket.invalidHandle
        #else
            return descriptor >= 0
        #endif
    }

    /// Returns the local bound `SocketAddress` of the socket.
    ///
    /// - returns: The local bound address.
    /// - throws: An `IOError` if the retrieval of the address failed.
    func localAddress() throws -> SocketAddress {
        return try get_addr {
            try NIOBSDSocket.getsockname(socket: $0, address: $1, address_len: $2)
        }
    }

    /// Returns the connected `SocketAddress` of the socket.
    ///
    /// - returns: The connected address.
    /// - throws: An `IOError` if the retrieval of the address failed.
    func remoteAddress() throws -> SocketAddress {
        return try get_addr {
            try NIOBSDSocket.getpeername(socket: $0, address: $1, address_len: $2)
        }
    }

    /// Internal helper function for retrieval of a `SocketAddress`.
    private func get_addr(_ body: (NIOBSDSocket.Handle, UnsafeMutablePointer<sockaddr>, UnsafeMutablePointer<socklen_t>) throws -> Void) throws -> SocketAddress {
        var addr = sockaddr_storage()

        try addr.withMutableSockAddr { addressPtr, size in
            var size = socklen_t(size)

            try self.withUnsafeHandle {
                try body($0, addressPtr, &size)
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
    static func makeSocket(protocolFamily: NIOBSDSocket.ProtocolFamily, type: NIOBSDSocket.SocketType, setNonBlocking: Bool = false) throws -> NIOBSDSocket.Handle {
        var sockType: CInt = type.rawValue
        #if os(Linux)
        if setNonBlocking {
            sockType = type.rawValue | Linux.SOCK_NONBLOCK
        }
        #endif
        let sock = try NIOBSDSocket.socket(domain: protocolFamily,
                                           type: NIOBSDSocket.SocketType(rawValue: sockType),
                                           protocol: 0)
        #if !os(Linux)
        if setNonBlocking {
            do {
                try NIOBSDSocket.setNonBlocking(socket: sock)
            } catch {
                // best effort close
                try? NIOBSDSocket.close(socket: sock)
                throw error
            }
        }
        #endif
        if protocolFamily == .inet6 {
            var zero: Int32 = 0
            do {
                try NIOBSDSocket.setsockopt(socket: sock, level: .ipv6, option_name: .ipv6_v6only, option_value: &zero, option_len: socklen_t(MemoryLayout.size(ofValue: zero)))
            } catch let e as IOError {
                if e.errnoCode != EAFNOSUPPORT {
                    // Ignore error that may be thrown by close.
                    _ = try? NIOBSDSocket.close(socket: sock)
                    throw e
                }
                /* we couldn't enable dual IP4/6 support, that's okay too. */
            } catch let e {
                fatalError("Unexpected error type \(e)")
            }
        }
        return sock
    }
    
    /// Cleanup the unix domain socket.
    ///
    /// Deletes the associated file if it exists and has socket type. Does nothing if pathname does not exist.
    ///
    /// - parameters:
    ///     - unixDomainSocketPath: The pathname of the UDS.
    /// - throws: An `UnixDomainSocketPathWrongType` if the pathname exists and is not a socket.
    static func cleanupSocket(unixDomainSocketPath: String) throws {
        try NIOBSDSocket.cleanupUnixDomainSocket(atPath: unixDomainSocketPath)
    }

    /// Create a new instance.
    ///
    /// The ownership of the passed in descriptor is transferred to this class. A user must call `close` to close the underlying
    /// file descriptor once it's not needed / used anymore.
    ///
    /// - parameters:
    ///     - descriptor: The file descriptor to wrap.
    init(socket descriptor: NIOBSDSocket.Handle) throws {
        #if os(Windows)
            precondition(descriptor != NIOBSDSocket.invalidHandle, "invalid socket")
        #else
            precondition(descriptor >= 0, "invalid socket")
        #endif
        self.descriptor = descriptor
        do {
            try self.ignoreSIGPIPE()
        } catch {
            self.descriptor = NIOBSDSocket.invalidHandle // We have to unset the fd here, otherwise we'll crash with "leaking open BaseSocket"
            throw error
        }
    }

    deinit {
        assert(!self.isOpen, "leak of open BaseSocket")
    }

    func ignoreSIGPIPE() throws {
        try BaseSocket.ignoreSIGPIPE(socket: self.descriptor)
    }

    /// Set the socket as non-blocking.
    ///
    /// All I/O operations will not block and so may return before the actual action could be completed.
    ///
    /// throws: An `IOError` if the operation failed.
    final func setNonBlocking() throws {
        return try self.withUnsafeHandle {
            try NIOBSDSocket.setNonBlocking(socket: $0)
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
    func setOption<T>(level: NIOBSDSocket.OptionLevel, name: NIOBSDSocket.Option, value: T) throws {
        if level == .tcp && name == .tcp_nodelay && (try? self.localAddress().protocol) == Optional<NIOBSDSocket.ProtocolFamily>.some(.unix) {
            // setting TCP_NODELAY on UNIX domain sockets will fail. Previously we had a bug where we would ignore
            // most socket options settings so for the time being we'll just ignore this. Let's revisit for NIO 2.0.
            return
        }
        return try self.withUnsafeHandle {
            var val = value

            try NIOBSDSocket.setsockopt(
                socket: $0,
                level: level,
                option_name: name,
                option_value: &val,
                option_len: socklen_t(MemoryLayout.size(ofValue: val)))
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
    final func getOption<T>(level: NIOBSDSocket.OptionLevel, name: NIOBSDSocket.Option) throws -> T {
        return try self.withUnsafeHandle { fd in
            var length = socklen_t(MemoryLayout<T>.size)
            let storage = UnsafeMutableRawBufferPointer.allocate(byteCount: MemoryLayout<T>.stride,
                                                                 alignment: MemoryLayout<T>.alignment)
            // write zeroes into the memory as Linux's getsockopt doesn't zero them out
            storage.initializeMemory(as: UInt8.self, repeating: 0)
            let val = storage.bindMemory(to: T.self).baseAddress!
            // initialisation will be done by getsockopt
            defer {
                val.deinitialize(count: 1)
                storage.deallocate()
            }

            try NIOBSDSocket.getsockopt(socket: fd, level: level, option_name: name, option_value: val, option_len: &length)
            return val.pointee
        }
    }

    /// Bind the socket to the given `SocketAddress`.
    ///
    /// - parameters:
    ///     - address: The `SocketAddress` to which the socket should be bound.
    /// - throws: An `IOError` if the operation failed.
    func bind(to address: SocketAddress) throws {
        try self.withUnsafeHandle { fd in
            try address.withSockAddr {
                try NIOBSDSocket.bind(socket: fd, address: $0, address_len: socklen_t($1))
            }
        }
    }

    /// Close the socket.
    ///
    /// After the socket was closed all other methods will throw an `IOError` when called.
    ///
    /// - throws: An `IOError` if the operation failed.
    func close() throws {
        try NIOBSDSocket.close(socket: try self.takeDescriptorOwnership())
    }

    /// Takes the file descriptor's ownership.
    ///
    /// After this call, `BaseSocket` considers itself to be closed and the caller is responsible for actually closing
    /// the underlying file descriptor.
    ///
    /// - throws: An `IOError` if the operation failed.
    final func takeDescriptorOwnership() throws -> NIOBSDSocket.Handle {
        return try self.withUnsafeHandle {
            self.descriptor = NIOBSDSocket.invalidHandle
            return $0
        }
    }
}

extension BaseSocket: Selectable {
    func withUnsafeHandle<T>(_ body: (NIOBSDSocket.Handle) throws -> T) throws -> T {
        guard self.isOpen else {
            throw IOError(errnoCode: EBADF, reason: "file descriptor already closed!")
        }
        return try body(self.descriptor)
    }
}

extension BaseSocket: CustomStringConvertible {
    var description: String {
        return "BaseSocket { fd=\(self.descriptor) }"
    }
}

// MARK: Workarounds for SR-14268
// We need these free functions to expose our extension methods, because otherwise
// the compiler falls over when we try to access them from test code. As these functions
// exist purely to make the behaviours accessible from test code, we name them truly awfully.
func __testOnly_convertSockAddr(_ addr: sockaddr_storage) -> sockaddr_in {
    return addr.convert()
}

func __testOnly_convertSockAddr(_ addr: sockaddr_storage) -> sockaddr_in6 {
    return addr.convert()
}

func __testOnly_convertSockAddr(_ addr: sockaddr_storage) -> sockaddr_un {
    return addr.convert()
}

func __testOnly_withMutableSockAddr<ReturnType>(
    _ addr: inout sockaddr_storage, _ body: (UnsafeMutablePointer<sockaddr>, Int) throws -> ReturnType
) rethrows -> ReturnType {
    return try addr.withMutableSockAddr(body)
}
