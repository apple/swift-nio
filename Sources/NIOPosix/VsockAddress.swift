//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

#if canImport(Darwin)
import CNIODarwin
#elseif os(Linux) || os(Android)
#if canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#endif
import CNIOLinux
#endif
let vsockUnimplemented = "VSOCK support is not implemented for this platform"

// MARK: - Public API that's available on all platforms.

/// A vsock socket address.
///
/// A socket address is defined as a combination of a Context Identifier (CID) and a port number.
/// The CID identifies the source or destination, which is either a virtual machine or the host.
/// The port number differentiates between multiple services running on a single machine.
///
/// For well-known CID values and port numbers, see ``VsockAddress/ContextID`` and ``VsockAddress/Port-swift.struct``.
public struct VsockAddress: Hashable, Sendable {
    /// The context ID associated with the address.
    public var cid: ContextID

    /// The port associated with the address.
    public var port: Port

    /// Creates a new vsock address.
    ///
    /// - Parameters:
    ///   - cid: the context ID.
    ///   - port: the target port.
    public init(cid: ContextID, port: Port) {
        self.cid = cid
        self.port = port
    }

    /// A vsock Context Identifier (CID).
    ///
    /// The CID identifies the source or destination, which is either a virtual machine or the host.
    public struct ContextID: RawRepresentable, ExpressibleByIntegerLiteral, Hashable, Sendable {
        public var rawValue: UInt32

        @inlinable
        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        @inlinable
        public init(integerLiteral value: UInt32) {
            self.init(rawValue: value)
        }

        @inlinable
        public init(_ value: Int) {
            self.init(rawValue: UInt32(bitPattern: Int32(truncatingIfNeeded: value)))
        }

        /// Wildcard, matches any address.
        ///
        /// On all platforms, using this value with `bind(2)` means "any address".
        ///
        /// On Darwin platforms, the man page states this can be used with `connect(2)` to mean "this host".
        ///
        /// This is equal to `VMADDR_CID_ANY (-1U)`.
        @inlinable
        public static var any: Self { Self(rawValue: UInt32(bitPattern: -1)) }

        /// The address of the hypervisor.
        ///
        /// This is equal to `VMADDR_CID_HYPERVISOR (0)`.
        @inlinable
        public static var hypervisor: Self { Self(rawValue: 0) }

        /// The address of the host.
        ///
        /// This is equal to `VMADDR_CID_HOST (2)`.
        @inlinable
        public static var host: Self { Self(rawValue: 2) }

        /// The address for local communication (loopback).
        ///
        /// This directs packets to the same host that generated them.  This is useful for testing
        /// applications on a single host and for debugging.
        ///
        /// The local context ID obtained with `getLocalContextID(_:)` can be used for the same
        /// purpose, but it is preferable to use `local`.
        ///
        /// This is equal to `VMADDR_CID_LOCAL (1)` on platforms that define it.
        ///
        /// - Warning: `VMADDR_CID_LOCAL (1)` is available from Linux 5.6. Its use is unsupported on
        /// other platforms.
        ///
        /// - SeeAlso: https://man7.org/linux/man-pages/man7/vsock.7.html
        @inlinable
        public static var local: Self { Self(rawValue: 1) }

    }

    /// A vsock port number.
    ///
    /// The vsock port number differentiates between multiple services running on a single machine.
    public struct Port: RawRepresentable, ExpressibleByIntegerLiteral, Hashable, Sendable {
        public var rawValue: UInt32

        @inlinable
        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        @inlinable
        public init(integerLiteral value: UInt32) {
            self.init(rawValue: value)
        }

        @inlinable
        public init(_ value: Int) {
            self.init(rawValue: UInt32(bitPattern: Int32(truncatingIfNeeded: value)))
        }

        /// Used to bind to any port number.
        ///
        /// This is equal to `VMADDR_PORT_ANY (-1U)`.
        @inlinable
        public static var any: Self { Self(rawValue: UInt32(bitPattern: -1)) }
    }
}

extension VsockAddress.ContextID: CustomStringConvertible {
    public var description: String {
        self == .any ? "-1" : self.rawValue.description
    }
}

extension VsockAddress.Port: CustomStringConvertible {
    public var description: String {
        self == .any ? "-1" : self.rawValue.description
    }
}

extension VsockAddress: CustomStringConvertible {
    public var description: String {
        "[VSOCK]\(self.cid):\(self.port)"
    }
}

extension ChannelOptions {
    /// - seealso: `LocalVsockContextID`
    public static let localVsockContextID = Types.LocalVsockContextID()
}

extension ChannelOption where Self == ChannelOptions.Types.LocalVsockContextID {
    public static var localVsockContextID: Self { .init() }
}

extension ChannelOptions.Types {
    /// This get-only option is used on channels backed by vsock sockets to get the local VSOCK context ID.
    public struct LocalVsockContextID: ChannelOption, Sendable {
        public typealias Value = VsockAddress.ContextID
        public init() {}
    }
}

// MARK: - Public API that might throw runtime error if not implemented on the platform.

extension NIOBSDSocket.AddressFamily {
    /// Address for vsock.
    public static var vsock: NIOBSDSocket.AddressFamily {
        #if canImport(Darwin) || os(Linux) || os(Android)
        NIOBSDSocket.AddressFamily(rawValue: AF_VSOCK)
        #else
        fatalError(vsockUnimplemented)
        #endif
    }
}

extension NIOBSDSocket.ProtocolFamily {
    /// Address for vsock.
    public static var vsock: NIOBSDSocket.ProtocolFamily {
        #if canImport(Darwin) || os(Linux) || os(Android)
        NIOBSDSocket.ProtocolFamily(rawValue: PF_VSOCK)
        #else
        fatalError(vsockUnimplemented)
        #endif
    }
}

extension VsockAddress {
    public func withSockAddr<T>(_ body: (UnsafePointer<sockaddr>, Int) throws -> T) rethrows -> T {
        #if canImport(Darwin) || os(Linux) || os(Android)
        return try self.address.withSockAddr({ try body($0, $1) })
        #else
        fatalError(vsockUnimplemented)
        #endif
    }
}

// MARK: - Internal functions that are only available on supported platforms.

#if canImport(Darwin) || os(Linux) || os(Android)
extension VsockAddress.ContextID {
    /// Get the context ID of the local machine.
    ///
    /// - Parameters:
    ///   - socketFD: the file descriptor for the open socket.
    ///
    /// This function wraps the `IOCTL_VM_SOCKETS_GET_LOCAL_CID` `ioctl()` request.
    ///
    /// To provide a consistent API on Linux and Darwin, this API takes a socket parameter, which is unused on Linux:
    ///
    /// - On Darwin, the `ioctl()` request operates on a socket.
    /// - On Linux, the `ioctl()` request operates on the `/dev/vsock` device.
    ///
    /// - Note: The semantics of this `ioctl` vary between vsock transports on Linux; ``local`` may be more suitable.
    static func getLocalContextID(_ socketFD: NIOBSDSocket.Handle) throws -> Self {
        #if canImport(Darwin)
        let request = CNIODarwin_IOCTL_VM_SOCKETS_GET_LOCAL_CID
        let fd = socketFD
        #elseif os(Linux) || os(Android)
        let request = CNIOLinux_IOCTL_VM_SOCKETS_GET_LOCAL_CID
        let fd = try Posix.open(file: "/dev/vsock", oFlag: O_RDONLY | O_CLOEXEC)
        defer { try! Posix.close(descriptor: fd) }
        #endif
        var cid = Self.any.rawValue
        try Posix.ioctl(fd: fd, request: request, ptr: &cid)
        return Self(rawValue: cid)
    }
}

extension sockaddr_vm {
    func withSockAddr<R>(_ body: (UnsafePointer<sockaddr>, Int) throws -> R) rethrows -> R {
        try withUnsafeBytes(of: self) { p in
            try body(p.baseAddress!.assumingMemoryBound(to: sockaddr.self), p.count)
        }
    }
}

extension VsockAddress {
    /// The libc socket address for a vsock socket.
    var address: sockaddr_vm {
        var addr = sockaddr_vm()
        addr.svm_family = sa_family_t(NIOBSDSocket.AddressFamily.vsock.rawValue)
        addr.svm_cid = self.cid.rawValue
        addr.svm_port = self.port.rawValue
        return addr
    }
}

extension sockaddr_storage {
    /// Converts the `socketaddr_storage` to a `sockaddr_vm`.
    ///
    /// This will crash if `ss_family` != AF_VSOCK!
    func convert() -> sockaddr_vm {
        precondition(self.ss_family == NIOBSDSocket.AddressFamily.vsock.rawValue)
        return withUnsafeBytes(of: self) {
            $0.load(as: sockaddr_vm.self)
        }
    }
}

extension BaseSocket {
    func bind(to address: VsockAddress) throws {
        try self.withUnsafeHandle { fd in
            try address.withSockAddr {
                try NIOBSDSocket.bind(socket: fd, address: $0, address_len: socklen_t($1))
            }
        }
    }

    func getLocalVsockContextID() throws -> VsockAddress.ContextID {
        try self.withUnsafeHandle { fd in
            try VsockAddress.ContextID.getLocalContextID(fd)
        }
    }
}

#endif  // canImport(Darwin) || os(Linux) || os(Android)
