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

public enum TLSUserEvent: Equatable {
    case handshakeCompleted
    case handshakeFailed(OpenSSLError)
    case cleanShutdown
    case uncleanShutdown
    case readError(OpenSSLError)
    case shutdownFailed(OpenSSLError)
}

public func ==(lhs: TLSUserEvent, rhs: TLSUserEvent) -> Bool {
    switch (lhs, rhs) {
    case (.handshakeCompleted, .handshakeCompleted):
        return true
    case (.handshakeFailed(let e1), .handshakeFailed(let e2)):
        return e1 == e2
    case (.cleanShutdown, .cleanShutdown):
        return true
    case (.uncleanShutdown, .uncleanShutdown):
        return true
    case (.readError(let e1), .readError(let e2)):
        return e1 == e2
    case (.shutdownFailed(let e1), .shutdownFailed(let e2)):
        return e1 == e2
    default:
        return false
    }
}
