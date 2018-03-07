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

/// An enum that represents websocket error codes.
///
/// This enum provides names to all non-reserved code numbers,
/// to avoid users needing to remember the specific numerical values
/// of those codes.
public enum WebSocketErrorCode {
    /// Indicates a normal closure, meaning that the purpose for
    /// which the connection was established has been fulfilled.
    /// Corresponds to code 1000.
    case normalClosure

    /// Ondicates that an endpoint is "going away", such as a server
    /// going down or a browser having navigated away from a page.
    /// Corresponds to code 1001.
    case goingAway

    /// Indicates that an endpoint is terminating the connection due
    /// to a protocol error.
    /// Corresponds to code 1002.
    case protocolError

    /// Indicates that an endpoint is terminating the connection
    /// because it has received a type of data it cannot accept (e.g. an
    /// endpoint that understands only text data may send this if it
    /// receives a binary message).
    /// Corresponds to code 1003.
    case unacceptableData

    /// Indicates that an endpoint is terminating the connection
    /// because it has received data within a message that was not
    /// consistent with the type of the message (e.g. non-UTF-8
    /// data within a text message).
    /// Corresponds to code 1007.
    case dataInconsistentWithMessage

    /// Indicates that an endpoint is terminating the connection
    /// because it has received a message that violates its policy.  This
    /// is a generic status code that can be returned when there is no
    /// other more suitable status code (e.g. 1003 or 1009) or if there
    /// is a need to hide specific details about the policy.
    /// Corresponds to code 1008.
    case policyViolation

    /// Indicates that an endpoint is terminating the connection
    /// because it has received a message that is too big for it to
    /// process.
    /// Corresponds to code 1009.
    case messageTooLarge

    /// Indicates that an endpoint (client) is terminating the
    /// connection because it has expected the server to negotiate one or
    /// more extension, but the server didn't return them in the response
    /// message of the WebSocket handshake.  The list of extensions that
    /// are needed should appear in the `reason` part of the Close frame.
    /// Note that this status code is not used by the server, because it
    /// can fail the WebSocket handshake instead.
    /// Corresponds to code 1010.
    case missingExtension

    /// Indicates that a server is terminating the connection because
    /// it encountered an unexpected condition that prevented it from
    /// fulfilling the request.
    /// Corresponds to code 1011.
    case unexpectedServerError

    /// We don't have a better name for this error code.
    case unknown(UInt16)

    /// Create an error code from a raw 16-bit integer as sent on the
    /// network.
    ///
    /// - parameters:
    ///     integer: The integer form of the status code.
    internal init(networkInteger integer: UInt16) {
        switch integer {
        case 1000:
            self = .normalClosure
        case 1001:
            self = .goingAway
        case 1002:
            self = .protocolError
        case 1003:
            self = .unacceptableData
        case 1007:
            self = .dataInconsistentWithMessage
        case 1008:
            self = .policyViolation
        case 1009:
            self = .messageTooLarge
        case 1010:
            self = .missingExtension
        case 1011:
            self = .unexpectedServerError
        default:
            self = .unknown(integer)
        }
    }

    /// Create an error code from an integer.
    ///
    /// Will trap if the error code is not in the valid range.
    ///
    /// - parameters:
    ///     - codeNumber: The integer form of the status code.
    public init(codeNumber: Int) {
        self.init(networkInteger: UInt16(codeNumber))
    }
}

extension WebSocketErrorCode: Equatable {
    public static func ==(lhs: WebSocketErrorCode, rhs: WebSocketErrorCode) -> Bool {
        switch (lhs, rhs) {
        case (.normalClosure, .normalClosure),
             (.goingAway, .goingAway),
             (.protocolError, .protocolError),
             (.unacceptableData, .unacceptableData),
             (.dataInconsistentWithMessage, .dataInconsistentWithMessage),
             (.policyViolation, .policyViolation),
             (.messageTooLarge, .messageTooLarge),
             (.missingExtension, .missingExtension),
             (.unexpectedServerError, .unexpectedServerError):
            return true
        case (.unknown(let l), .unknown(let r)):
            return l == r
        default:
            return false
        }
    }
}

public extension ByteBuffer {
    /// Read a websocket error code from a byte buffer.
    ///
    /// This method increments the reader index.
    ///
    /// - returns: The error code, or `nil` if there were not enough readable bytes.
    public mutating func readWebSocketErrorCode() -> WebSocketErrorCode? {
        return self.readInteger(as: UInt16.self).map { WebSocketErrorCode(networkInteger: $0) }
    }

    /// Get a websocket error code from a byte buffer.
    ///
    /// This method does not increment the reader index, and may be used to read an error
    /// code from outside the readable range of bytes.
    ///
    /// - parameters:
    ///     - index: The index into the buffer to read the error code from.
    /// - returns: The error code, or `nil` if there were not enough bytes at that index.
    public func getWebSocketErrorCode(at index: Int) -> WebSocketErrorCode? {
        return self.getInteger(at: index, as: UInt16.self).map { WebSocketErrorCode(networkInteger: $0) }
    }

    /// Write the given error code to the buffer.
    ///
    /// - parameters:
    ///     - code: The code to write into the buffer.
    public mutating func write(webSocketErrorCode code: WebSocketErrorCode) {
        self.write(integer: UInt16(webSocketErrorCode: code))
    }
}

public extension UInt16 {
    /// Create a UInt16 corresponding to a given `WebSocketErrorCode`.
    ///
    /// - parameters:
    ///     - code: The `WebSocketErrorCode`.
    public init(webSocketErrorCode code: WebSocketErrorCode) {
        switch code {
        case .normalClosure:
            self = 1000
        case .goingAway:
            self = 1001
        case .protocolError:
            self = 1002
        case .unacceptableData:
            self = 1003
        case .dataInconsistentWithMessage:
            self = 1007
        case .policyViolation:
            self = 1008
        case .messageTooLarge:
            self = 1009
        case .missingExtension:
            self = 1010
        case .unexpectedServerError:
            self = 1011
        case .unknown(let i):
            self = i
        }
    }
}
