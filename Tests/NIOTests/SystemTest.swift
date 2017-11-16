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

import XCTest
@testable import NIO

public func measureRunTime(_ fn: () throws -> Int) rethrows -> TimeInterval {
    func measureOne(_ fn: () throws -> Int) rethrows -> TimeInterval {
        let start = Date()
        _ = try fn()
        let end = Date()
        return end.timeIntervalSince(start)
    }
    
    _ = try measureOne(fn)
    var measurements = Array(repeating: 0.0, count: 10)
    for i in 0..<10 {
        measurements[i] = try measureOne(fn)
    }
    
    //return measurements.reduce(0, +) / 10.0
    return measurements.min()!
}

public func measureRunTimeAndPrint(desc: String, fn: () throws -> Int) rethrows -> Void {
    print("measuring: \(desc)")
    print("\(try measureRunTime(fn))s")
}

enum TestIOError: Error {
    case writeFailed
}

class SystemTest: XCTestCase {
    func testSystemCallWrapperPerformance() throws {
        let fd = open("/dev/null", O_WRONLY)
        precondition(fd >= 0, "couldn't open /dev/null (\(errno))")
        defer {
            close(fd)
        }
        
        let isDebugMode = _isDebugAssertConfiguration()
        
        let iterations = isDebugMode ? 100_000 : 1_000_000
        let pointer = UnsafePointer<UInt8>(bitPattern: 0xdeadbeef)!
        
        let directCallTime = try measureRunTime { () -> Int in
            /* imitate what the system call wrappers do to have a fair comparison */
            var preventCompilerOptimisation: Int = 0
            for _ in 0..<iterations {
                while true {
                    let r = write(fd, pointer, 0)
                    if r < 0 {
                        let saveErrno = errno
                        switch saveErrno {
                        case EINTR:
                            continue
                        case EWOULDBLOCK:
                            XCTFail()
                        case EBADF, EFAULT:
                            fatalError()
                        default:
                            throw TestIOError.writeFailed
                        }
                    } else {
                        preventCompilerOptimisation += r
                        break
                    }
                }
            }
            return preventCompilerOptimisation
        }
        
        let withSystemCallWrappersTime = try measureRunTime { () -> Int in
            var preventCompilerOptimisation: Int = 0
            for _ in 0..<iterations {
                switch try Posix.write(descriptor: fd, pointer: pointer, size: 0) {
                case .processed(let v):
                    preventCompilerOptimisation += v
                case .wouldBlock(_):
                    XCTFail()
                }
            }
            return preventCompilerOptimisation
        }
        
        let allowedOverheadPercent: Int = isDebugMode ? 1000 : 20
        if allowedOverheadPercent > 100 {
            precondition(isDebugMode)
            print("WARNING: Syscall wrapper test: Over 100% overhead allowed. Running in debug assert configuration which allows \(allowedOverheadPercent)% overhead :(. Consider running in Release mode.")
        }
        XCTAssert(directCallTime * (1.0 + Double(allowedOverheadPercent)/100) > withSystemCallWrappersTime,
                  "Posix wrapper adds more than \(allowedOverheadPercent)% overhead (with wrapper: \(withSystemCallWrappersTime), without: \(directCallTime)")
    }
}
