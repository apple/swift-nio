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
#if os(macOS) || os(tvOS) || os(iOS)
    import Darwin
#else
    import Glibc
#endif
import NIO

private extension String {
    func isIPAddress() -> Bool {
        // We need some scratch space to let inet_pton write into.
        var ipv4Addr = in_addr()
        var ipv6Addr = in6_addr()

        return self.withCString { ptr in
            return inet_pton(AF_INET, ptr, &ipv4Addr) == 1 ||
                   inet_pton(AF_INET6, ptr, &ipv6Addr) == 1
        }
    }
}

/// A channel handler that wraps a channel in TLS using OpenSSL, or an
/// OpenSSL-compatible library. This handler can be used in channels that
/// are acting as the client in the TLS dialog. For server connections,
/// use the OpenSSLServerHandler.
public final class OpenSSLClientHandler: OpenSSLHandler {
    public init(context: SSLContext, serverHostname: String? = nil) throws {
        guard let connection = context.createConnection() else {
            throw NIOOpenSSLError.unableToAllocateOpenSSLObject
        }

        connection.setConnectState()
        if let serverHostname = serverHostname {
            if serverHostname.isIPAddress() {
                throw OpenSSLError.invalidSNIName([])
            }

            // IP addresses must not be provided in the SNI extension, so filter them.
            try connection.setSNIServerName(name: serverHostname)
        }
        super.init(connection: connection, expectedHostname: serverHostname)
    }
}
