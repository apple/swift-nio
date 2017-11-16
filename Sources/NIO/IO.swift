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
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public struct IOError: Swift.Error {
    
    public let errno: Int32
    // TODO: Fix me to lazy create
    public let reason: String?
    
    public init(errno errnoNumber: Int32, reason: String) {
        self.errno = errnoNumber
        self.reason = reason
    }
}

func ioError(errno: Int32, function: String) -> IOError {
    return IOError(errno: errno, reason: reasonForError(errno: errno, function: function))
}

func reasonForError(errno: Int32, function: String) -> String {
    if let strError = String(utf8String: strerror(errno)) {
        return "\(function) failed: errno(\(errno)) \(strError)"
    } else {
        return "\(function) failed"
    }
}

public enum IOResult<T> {
    case wouldBlock(T)
    case processed(T)
}
