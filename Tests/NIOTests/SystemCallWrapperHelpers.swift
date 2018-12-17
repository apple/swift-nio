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
#if !RUNNING_INTEGRATION_TESTS
@testable import NIO
#endif

public func measureRunTime(_ body: () throws -> Int) rethrows -> TimeInterval {
    func measureOne(_ body: () throws -> Int) rethrows -> TimeInterval {
        let start = Date()
        _ = try body()
        let end = Date()
        return end.timeIntervalSince(start)
    }

    _ = try measureOne(body)
    var measurements = Array(repeating: 0.0, count: 10)
    for i in 0..<10 {
        measurements[i] = try measureOne(body)
    }

    //return measurements.reduce(0, +) / 10.0
    return measurements.min()!
}

public func measureRunTimeAndPrint(desc: String, body: () throws -> Int) rethrows -> Void {
    print("measuring: \(desc)")
    print("\(try measureRunTime(body))s")
}

enum TestError: Error {
    case writeFailed
    case wouldBlock
}

func runStandalone() {
    func assertFun(condition: @autoclosure () -> Bool, string: @autoclosure () -> String, file: StaticString, line: UInt) -> Void {
        if !condition() {
            fatalError(string(), file: file, line: line)
        }
    }
    do {
        try runSystemCallWrapperPerformanceTest(testAssertFunction: assertFun, debugModeAllowed: false)
    } catch let e {
        fatalError("Error thrown: \(e)")
    }
}

func runSystemCallWrapperPerformanceTest(testAssertFunction: (@autoclosure () -> Bool, @autoclosure () -> String, StaticString, UInt) -> Void,
                                         debugModeAllowed: Bool) throws {
    let fd = open("/dev/null", O_WRONLY)
    precondition(fd >= 0, "couldn't open /dev/null (\(errno))")
    defer {
        close(fd)
    }

    let isDebugMode = _isDebugAssertConfiguration()
    if !debugModeAllowed && isDebugMode {
        fatalError("running in debug mode, release mode required")
    }

    let iterations = isDebugMode ? 100_000 : 1_000_000
    let pointer = UnsafePointer<UInt8>(bitPattern: 0xdeadbee)!

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
                        throw TestError.wouldBlock
                    case EBADF, EFAULT:
                        fatalError()
                    default:
                        throw TestError.writeFailed
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
            case .wouldBlock:
                throw TestError.wouldBlock
            }
        }
        return preventCompilerOptimisation
    }

    let allowedOverheadPercent: Int = isDebugMode ? 1000 : 20
    if allowedOverheadPercent > 100 {
        precondition(isDebugMode)
        print("WARNING: Syscall wrapper test: Over 100% overhead allowed. Running in debug assert configuration which allows \(allowedOverheadPercent)% overhead :(. Consider running in Release mode.")
    }
    testAssertFunction(directCallTime * (1.0 + Double(allowedOverheadPercent)/100) > withSystemCallWrappersTime,
                       "Posix wrapper adds more than \(allowedOverheadPercent)% overhead (with wrapper: \(withSystemCallWrappersTime), without: \(directCallTime)",
                       #file, #line)
}
