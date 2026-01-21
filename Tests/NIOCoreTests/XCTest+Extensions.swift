//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import XCTest

#if canImport(Android)
import Android
#endif

func assert(
    _ condition: @autoclosure () -> Bool,
    within time: TimeAmount,
    testInterval: TimeAmount? = nil,
    _ message: String = "condition not satisfied in time",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let testInterval = testInterval ?? TimeAmount.nanoseconds(time.nanoseconds / 5)
    let endTime = NIODeadline.now() + time

    repeat {
        if condition() { return }
        usleep(UInt32(testInterval.nanoseconds / 1000))
    } while NIODeadline.now() < endTime

    if !condition() {
        XCTFail(message, file: (file), line: line)
    }
}

func assertNoThrowWithValue<T>(
    _ body: @autoclosure () throws -> T,
    defaultValue: T? = nil,
    message: String? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    do {
        return try body()
    } catch {
        XCTFail("\(message.map { $0 + ": " } ?? "")unexpected error \(error) thrown", file: (file), line: line)
        if let defaultValue = defaultValue {
            return defaultValue
        } else {
            throw error
        }
    }
}

func withTemporaryFile<T>(content: String? = nil, _ body: (NIOCore.NIOFileHandle, String) throws -> T) throws -> T {
    let temporaryFilePath = "\(temporaryDirectory)/nio_\(UUID())"
    _ = FileManager.default.createFile(atPath: temporaryFilePath, contents: content?.data(using: .utf8))
    defer {
        XCTAssertNoThrow(try FileManager.default.removeItem(atPath: temporaryFilePath))
    }

    let fileHandle = try NIOFileHandle(_deprecatedPath: temporaryFilePath, mode: [.read, .write])
    defer {
        XCTAssertNoThrow(try fileHandle.close())
    }

    return try body(fileHandle, temporaryFilePath)
}

private var temporaryDirectory: String {
    get {
        #if targetEnvironment(simulator)
        // Simulator temp directories are so long (and contain the user name) that they're not usable
        // for UNIX Domain Socket paths (which are limited to 103 bytes).
        return "/tmp"
        #else
        #if os(Linux)
        return "/tmp"
        #else
        if #available(macOS 10.12, iOS 10, tvOS 10, watchOS 3, *) {
            return FileManager.default.temporaryDirectory.path
        } else {
            return "/tmp"
        }
        #endif  // os
        #endif  // targetEnvironment
    }
}
