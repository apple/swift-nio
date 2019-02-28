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
public struct WebSocketOpcode {
    fileprivate let networkRepresentation: UInt8

    public static let continuation = WebSocketOpcode(rawValue: 0x0)
    public static let text = WebSocketOpcode(rawValue: 0x1)
    public static let binary = WebSocketOpcode(rawValue: 0x2)
    public static let connectionClose = WebSocketOpcode(rawValue: 0x8)
    public static let ping = WebSocketOpcode(rawValue: 0x9)
    public static let pong = WebSocketOpcode(rawValue: 0xA)

    /// Create an opcode from the encoded representation.
    ///
    /// - parameters
    ///     - encoded: The encoded representation of the opcode as an 8-bit integer.
    ///          Must be no more than 4 bits large.
    public init?(encodedWebSocketOpcode encoded: UInt8) {
        guard encoded < 0x10 else {
            return nil
        }

        self.networkRepresentation = encoded
    }

    /// Create an opcode directly with no validation.
    ///
    /// Used only to create the static lets on this structure.
    private init(rawValue: UInt8) {
        self.networkRepresentation = rawValue
    }

    /// Whether the opcode is in the control range: that is, if the
    /// high bit of the opcode nibble is `1`.
    public var isControlOpcode: Bool {
        return self.networkRepresentation & 0x8 == 0x8
    }
}

extension WebSocketOpcode: Equatable { }

extension WebSocketOpcode: Hashable { }

extension WebSocketOpcode: CaseIterable {
    public static var allCases = (0..<0x10).map { WebSocketOpcode(rawValue: $0) }
}

extension WebSocketOpcode: CustomStringConvertible {
    public var description: String {
        switch self {
        case .continuation:
            return "WebSocketOpcode.continuation"
        case .text:
            return "WebSocketOpcode.text"
        case .binary:
            return "WebSocketOpcode.binary"
        case .connectionClose:
            return "WebSocketOpcode.connectionClose"
        case .ping:
            return "WebSocketOpcode.ping"
        case .pong:
            return "WebSocketOpcode.pong"
        case let x where x.isControlOpcode:
            return "WebSocketOpcode.unknownControl(\(x.networkRepresentation))"
        case let x:
            return "WebSocketOpcode.unknownNonControl(\(x.networkRepresentation))"
        }
    }
}

extension UInt8 {
    /// Create a UInt8 corresponding to a given `WebSocketOpcode`.
    ///
    /// This places the opcode in the four least-significant bits, in
    /// a form suitable for sending on the wire.
    ///
    /// - parameters:
    ///     - opcode: The `WebSocketOpcode`.
    public init(webSocketOpcode opcode: WebSocketOpcode) {
        precondition(opcode.networkRepresentation < 0x10)
        self = opcode.networkRepresentation
    }
}

extension Int {
    /// Create a UInt8 corresponding to the integer value for a given `WebSocketOpcode`.
    ///
    /// - parameters:
    ///     - opcode: The `WebSocketOpcode`.
    public init(webSocketOpcode opcode: WebSocketOpcode) {
        precondition(opcode.networkRepresentation < 0x10)
        self = Int(opcode.networkRepresentation)
    }
}
