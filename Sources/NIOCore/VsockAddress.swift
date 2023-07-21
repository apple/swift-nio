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
#if canImport(Darwin) || os(Linux)

#if canImport(Darwin)
import Darwin
import CNIODarwin
fileprivate let get_local_vsock_cid: @convention(c) (CInt) -> UInt32 = CNIODarwin_get_local_vsock_cid
#elseif os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import CNIOLinux
fileprivate let get_local_vsock_cid: @convention(c) (CInt) -> UInt32 = CNIOLinux_get_local_vsock_cid
#else
#error("Unable to identify your C library.")
#endif

/// A vsock socket address.
///
/// A socket address is defined as a combination of a Context Identifier (CID) and a port number.
/// The CID identifies the source or destination, which is either a virtual machine or the host.
/// The port number differentiates between multiple services running on a single machine.
///
/// For well-known CID values and port numbers, see ``ContextID`` and ``Port`` respectively.
public struct VsockAddress: Sendable {
    private let _storage: Box<sockaddr_vm>

    /// The libc socket address for a vsock socket.
    public var address: sockaddr_vm { return _storage.value }

    /// Get the context ID associated with the address.
    public var cid: Int {
        Int(Int32(bitPattern: self.address.svm_cid))
    }

    /// Get the port associated with the address.
    public var port: Int {
        Int(Int32(bitPattern: self.address.svm_port))
    }

    /// Creates a new vsock address.
    ///
    /// - parameters:
    ///     - address: the `sockaddr_vm` that holds the context ID and port.
    public init(address: sockaddr_vm) {
        self._storage = Box(address)
    }

    public init(cid: UInt32, port: UInt32) {
        var addr = sockaddr_vm()
        addr.svm_family = sa_family_t(NIOBSDSocket.AddressFamily.vsock.rawValue)
        addr.svm_cid = cid
        addr.svm_port = port
        self.init(address: addr)
    }

    /// Creates a new vsock address.
    ///
    /// - parameters:
    ///   - cid: the context ID.
    ///   - port: the target port.
    /// - returns: the `SocketAddress` for the given context ID and port combination.
    public init(cid: Int, port: Int) {
        self.init(cid: UInt32(bitPattern: Int32(truncatingIfNeeded: cid)), port: UInt32(bitPattern: Int32(truncatingIfNeeded: port)))
    }

    /// Get the local context ID for a vsock socket.
    ///
    /// - parameters:
    ///   - socket: The vsock socket to get the local context ID for.
    ///
    /// - NOTE: On Linux, you can use `VMADDR_CID_LOCAL` to retrieve the local context ID, which does not require a socket.
    public static func localVsockContextID(_ socket: NIOBSDSocket.Handle) -> Int {
        Int(get_local_vsock_cid(socket))
    }
}

extension VsockAddress {
    /// A vsock Context Identifier (CID).
    ///
    /// The CID identifies the source or destination, which is either a virtual machine or the host.
    public struct ContextID: RawRepresentable, ExpressibleByIntegerLiteral, Hashable, Sendable {
        public var rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public init(integerLiteral value: UInt32) {
            self.init(rawValue: value)
        }

        /// Wildcard, matches any address.
        ///
        /// On all platforms, using this value with `bind(2)` means "any address".
        ///
        /// On Darwin platforms, the man page states this can be used with `connect(2)` to mean "this host".
        public static let any: Self = Self(rawValue: VMADDR_CID_ANY)

        /// The address of the hypervisor.
        public static let hypervisor: Self = Self(rawValue: UInt32(VMADDR_CID_HYPERVISOR))

        /// The address of the host.
        public static let host: Self = Self(rawValue: UInt32(VMADDR_CID_HOST))

#if os(Linux)
        /// The address for local communication (loopback).
        ///
        /// This directs packets to the same host that generated them.  This is useful for testing
        /// applications on a single host and for debugging.
        ///
        /// The local context ID obtained with ``getLocalContextID(_:)`` can be used for the same
        /// purpose, but it is preferable to use ``local``.
        public static let local: Self = Self(rawValue: UInt32(VMADDR_CID_LOCAL))
#endif

        /// Get the context ID of the local machine.
        ///
        /// On Linux, consider using ``local`` when binding instead of this function.
        public static func getLocalContextID(_ socket: NIOBSDSocket.Handle) -> Self {
            Self(rawValue: get_local_vsock_cid(socket))
        }
    }

    /// A vsock port number.
    ///
    /// The vsock port number differentiates between multiple services running on a single machine.
    public struct Port: RawRepresentable, ExpressibleByIntegerLiteral, Hashable, Sendable {
        public var rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public init(integerLiteral value: UInt32) {
            self.init(rawValue: value)
        }

        /// Used to bind to any port number.
        public static let any: Self = Self(rawValue: VMADDR_PORT_ANY)
    }

    /// Creates a new vsock address.
    ///
    /// - parameters:
    ///   - cid: the context ID.
    ///   - port: the target port.
    /// - returns: the `SocketAddress` for the given context ID and port combination.
    public init(cid: ContextID, port: Port) {
        self.init(cid: cid.rawValue, port: port.rawValue)
    }
}

extension VsockAddress: CustomStringConvertible {
    public var description: String {
        "[VSOCK]\(self.cid):\(self.port)"
    }
}

/// Element-wise Equatable conformance using only the struct fields defined in the man page (excluding lengths).
extension VsockAddress: Equatable {
    public static func == (lhs: VsockAddress, rhs: VsockAddress) -> Bool {
        (
            lhs.address.svm_family == rhs.address.svm_family
            && lhs.address.svm_reserved1 == rhs.address.svm_reserved1
            && lhs.address.svm_port == rhs.address.svm_port
            && lhs.address.svm_cid == rhs.address.svm_cid
        )
    }
}

/// Element-wise Hashable conformance using only the struct fields defined in the man page (excluding lengths).
extension VsockAddress: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.address.svm_family)
        hasher.combine(self.address.svm_reserved1)
        hasher.combine(self.address.svm_port)
        hasher.combine(self.address.svm_cid)
    }
}

extension VsockAddress: SockAddrProtocol {
    public func withSockAddr<T>(_ body: (UnsafePointer<sockaddr>, Int) throws -> T) rethrows -> T {
        try self.address.withSockAddr({ try body($0, $1) })
    }
}

extension NIOBSDSocket.AddressFamily {
    /// Address for vsock.
    public static let vsock: NIOBSDSocket.AddressFamily =
            NIOBSDSocket.AddressFamily(rawValue: AF_VSOCK)
}

extension NIOBSDSocket.ProtocolFamily {
    /// Vsock protocol.
    public static let vsock: NIOBSDSocket.ProtocolFamily =
            NIOBSDSocket.ProtocolFamily(rawValue: PF_VSOCK)
}

extension sockaddr_vm: SockAddrProtocol {
    func withSockAddr<R>(_ body: (UnsafePointer<sockaddr>, Int) throws -> R) rethrows -> R {
        return try withUnsafeBytes(of: self) { p in
            try body(p.baseAddress!.assumingMemoryBound(to: sockaddr.self), p.count)
        }
    }
}
#endif  // canImport(Darwin) || os(Linux)
