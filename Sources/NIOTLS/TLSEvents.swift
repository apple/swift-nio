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

/// Common user events sent by all TLS implementations.
public enum TLSUserEvent: Equatable {
    /// The TLS handshake has completed. If ALPN or NPN were used,
    /// the negotiated protocol is provided as `negotiatedProtocol`.
    case handshakeCompleted(negotiatedProtocol: String?)

    /// The TLS connection has been successfully and cleanly shut down.
    /// No further application data can be sent or received at this time.
    case shutdownCompleted
}
