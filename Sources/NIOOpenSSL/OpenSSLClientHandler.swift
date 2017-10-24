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

import NIO

/// A channel handler that wraps a channel in TLS using OpenSSL, or an
/// OpenSSL-compatible library. This handler can be used in channels that
/// are acting as the client in the TLS dialog. For server connections,
/// use the OpenSSLServerHandler.
public final class OpenSSLClientHandler: OpenSSLHandler {
    public init(context: SSLContext) throws {
        guard let connection = context.createConnection() else {
            throw NIOOpenSSLError.unableToAllocateOpenSSLObject
        }

        connection.setConnectState()
        super.init(connection: connection)
    }
}
