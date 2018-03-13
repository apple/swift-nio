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

/// An operation code for a websocket frame.
public enum WebSocketOpcode {
    case continuation
    case text
    case binary
    case unknownNonControl(UInt8)
    case connectionClose
    case ping
    case pong
    case unknownControl(UInt8)

    /// Create an opcode from the encoded representation.
    ///
    /// - parameters
    ///     - encoded: The encoded representation of the opcode as an 8-bit integer.
    ///          Must be no more than 4 bits large.
    public init?(encodedWebSocketOpcode encoded: UInt8) {
        guard encoded < 0x10 else {
            return nil
        }

        switch encoded {
        case 0x0:
            self = .continuation
        case 0x1:
            self = .text
        case 0x2:
            self = .binary
        case 0x8:
            self = .connectionClose
        case 0x9:
            self = .ping
        case 0xA:
            self = .pong
        case let oc where (oc & 0x8) != 0:
            self = .unknownControl(oc)
        default:
            self = .unknownNonControl(encoded)
        }
    }

    /// Whether the opcode is in the control range: that is, if the
    /// high bit of the opcode nibble is `1`.
    public var isControlOpcode: Bool {
        switch self {
        case .connectionClose,
             .ping,
             .pong,
             .unknownControl:
            return true
        default:
            return false
        }
    }
}

extension WebSocketOpcode: Equatable {
    public static func ==(lhs: WebSocketOpcode, rhs: WebSocketOpcode) -> Bool {
        switch (lhs, rhs) {
        case (.continuation, .continuation),
             (.text, .text),
             (.binary, .binary),
             (.connectionClose, .connectionClose),
             (.ping, .ping),
             (.pong, .pong):
            return true
        case (.unknownControl(let i), .unknownControl(let j)),
             (.unknownNonControl(let i), .unknownNonControl(let j)):
            return i == j
        default:
            return false
        }
    }
}

public extension UInt8 {
    /// Create a UInt8 corresponding to a given `WebSocketOpcode`.
    ///
    /// This places the opcode in the four least-significant bits, in
    /// a form suitable for sending on the wire. Will fail if the opcode
    /// is not actually a valid websocket opcode
    ///
    /// - parameters:
    ///     - opcode: The `WebSocketOpcode`.
    public init?(webSocketOpcode opcode: WebSocketOpcode) {
        switch opcode {
        case .continuation:
            self = 0x0
        case .text:
            self = 0x1
        case .binary:
            self = 0x2
        case .connectionClose:
            self = 0x8
        case .ping:
            self = 0x9
        case .pong:
            self = 0xA
        case .unknownControl(let i),
             .unknownNonControl(let i):
            guard i < 0x10 else { return nil }
            self = i
        }
    }
}
