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
import NIOCore
#if canImport(Darwin)
import CNIODarwin
#else
import CNIOLinux
#endif

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
}
#endif  // canImport(Darwin) || os(Linux)
