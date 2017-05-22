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

import Foundation
import Errno

public struct IOError: Swift.Error {
    
    public let errno: Int32
    public let reason: String?
    
    public init(errno: Int32, reason: String) {
        self.errno = errno
        self.reason = reason
    }
}

func ioError(errno: Int32, function: String) -> IOError {
    return IOError(errno: errno, reason: reasonForError(errno: errno, function: function))
}

func reasonForError(errno: Int32, function: String) -> String {
    if let strError = String(utf8String: strerror(errno)) {
        return "\(function) failed: \(strError)"
    } else {
        return "\(function) failed"
    }
}

func wrapSyscall<A>(function: @autoclosure () -> String,
                    _ successCondition: (A) -> Bool, _ fn: () -> A) throws -> A {
    do {
        return try withErrno(hint: "", successCondition: successCondition, fn)
    } catch let e as POSIXReasonedError {
        throw ioError(errno: e.code, function: function())
    }
}

func wrapSyscall<A>(_ successCondition: (A) -> Bool,
                        function: @autoclosure () -> String, _ fn: () -> A) throws -> A {
    return try wrapSyscall(function: function, successCondition, fn)
}

func wrapSyscallMayBlock<A>(_ successCondition: (A) -> Bool,
                 function: @autoclosure () -> String, _ fn: () -> A) throws -> A? {
    do {
        return try wrapSyscall(function: function, successCondition, fn)
    } catch let error as IOError {
        if error.errno == EWOULDBLOCK {
            return nil;
        }
        throw error
    }
}
