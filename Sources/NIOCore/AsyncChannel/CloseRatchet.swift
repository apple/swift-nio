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
#if swift(>=5.6)
/// A helper type that lets ``NIOAsyncChannelAdapterHandler`` and ``NIOAsyncChannelWriterHandler`` collude
/// to ensure that the ``Channel`` they share is closed appropriately.
///
/// The strategy of this type is that it keeps track of which side has closed, so that the handlers can work out
/// which of them was "last", in order to arrange closure.
@usableFromInline
final class CloseRatchet {
    @usableFromInline
    enum State {
        case notClosed
        case readClosed
        case writeClosed
        case bothClosed

        @inlinable
        mutating func closeRead() -> Action {
            switch self {
            case .notClosed:
                self = .readClosed
                return .nothing
            case .writeClosed:
                self = .bothClosed
                return .close
            case .readClosed, .bothClosed:
                preconditionFailure("Duplicate read closure")
            }
        }

        @inlinable
        mutating func closeWrite() -> Action {
            switch self {
            case .notClosed:
                self = .writeClosed
                return .nothing
            case .readClosed:
                self = .bothClosed
                return .close
            case .writeClosed, .bothClosed:
                preconditionFailure("Duplicate write closure")
            }
        }
    }

    @usableFromInline
    enum Action {
        case nothing
        case close
    }

    @usableFromInline
    var _state: State

    @inlinable
    init() {
        self._state = .notClosed
    }

    @inlinable
    func closeRead() -> Action {
        return self._state.closeRead()
    }

    @inlinable
    func closeWrite() -> Action {
        return self._state.closeWrite()
    }
}
#endif
