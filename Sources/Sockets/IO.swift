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

@inline(never)
private func callWithErrno<A>(_ fn: () -> A) -> (result: A, errno_value: Int32) {
    var result: A? = nil
    var savedErrno: Int32 = 0
    withExtendedLifetime(fn) {
        result = fn()
        savedErrno = errno
    }
    return (result!, savedErrno)
}

func wrapSyscall<A>(function: @autoclosure () -> String,
                        _ successCondition: (A) -> Bool, _ fn: () -> A) throws -> A {
    while true {
        let (result, err) = callWithErrno(fn)
        if !successCondition(result) {
            precondition(err != 0, "errno is 0, successCondition wrong")
            precondition(![EBADF, EFAULT].contains(err), "backlisted errno \(err) on \(function())")
            if err == EINTR {
                continue
            }
            throw ioError(errno: err, function: function())
        } else {
            return result
        }
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
