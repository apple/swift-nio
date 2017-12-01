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
    
    public let errnoCode: Int32
    // TODO: Fix me to lazy create
    public let reason: String
    
    public init(errnoCode: Int32, reason: String) {
        self.errnoCode = errnoCode
        self.reason = reason
    }
}

func ioError(errno: Int32, function: String) -> IOError {
    return IOError(errnoCode: errno, reason: reasonForError(errnoCode: errno, function: function))
}

private func reasonForError(errnoCode: Int32, function: String) -> String {
    if let errorDescC = strerror(errnoCode) {
        let errorDescLen = strlen(errorDescC)
        return errorDescC.withMemoryRebound(to: UInt8.self, capacity: errorDescLen) { ptr in
            let errorDescPtr = UnsafeBufferPointer<UInt8>(start: ptr, count: errorDescLen)
            return "\(function) failed: \(String(decoding: errorDescPtr, as: UTF8.self)) (errno: \(errnoCode)) "
        }
    } else {
        return "\(function) failed: Broken strerror, unknown error: \(errnoCode)"
    }
}

extension IOError {
    public var localizedDescription: String {
        return self.reason
    }
}

public enum IOResult<T> {
    case wouldBlock(T)
    case processed(T)
}
