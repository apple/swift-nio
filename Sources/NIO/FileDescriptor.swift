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

public protocol FileDescriptor {

    /// Will be called with the file descriptor if still open, if not it will
    /// throw an `IOError`.
    ///
    /// The ownership of the file descriptor must not escape the `body` as it's completely managed by the
    /// implementation of the `FileDescriptor` protocol.
    ///
    /// - parameters:
    ///     - body: The closure to execute if the `FileDescriptor` is still open.
    /// - throws: If either the `FileDescriptor` was closed before or the closure throws by itself.
    func withUnsafeFileDescriptor<T>(_ body: (CInt) throws -> T) throws -> T

    /// `true` if this `FileDescriptor` is open (which means it was not closed yet).
    var isOpen: Bool { get }

    /// Close this `FileDescriptor`.
    func close() throws
}

extension FileDescriptor {
    internal static func setNonBlocking(fileDescriptor: CInt) throws {
        let flags = try Posix.fcntl(descriptor: fileDescriptor, command: F_GETFL, value: 0)
        do {
            let ret = try Posix.fcntl(descriptor: fileDescriptor, command: F_SETFL, value: flags | O_NONBLOCK)
            assert(ret == 0, "unexpectedly, fcntl(\(fileDescriptor), F_SETFL, \(flags) | O_NONBLOCK) returned \(ret)")
        } catch let error as IOError {
            if error.errnoCode == EINVAL {
                // Darwin seems to sometimes do this despite the docs claiming it can't happen
                throw NIOFcntlFailedError()
            }
            throw error
        }
    }
}
