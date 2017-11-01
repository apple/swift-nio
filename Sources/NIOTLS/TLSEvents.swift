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
    case handshakeCompleted(negotiatedProtocol: String?)
    case shutdownCompleted

    public static func ==(lhs: TLSUserEvent, rhs: TLSUserEvent) -> Bool {
        switch (lhs, rhs) {
        case (.handshakeCompleted(let p1), .handshakeCompleted(let p2)):
            return p1 == p2
        case (.shutdownCompleted, .shutdownCompleted):
            return true
        default:
            return false
        }
    }
}
