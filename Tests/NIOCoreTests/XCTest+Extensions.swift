//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
import NIOCore
import struct System.FileDescriptor

func assert(_ condition: @autoclosure () -> Bool, within time: TimeAmount, testInterval: TimeAmount? = nil, _ message: String = "condition not satisfied in time", file: StaticString = #file, line: UInt = #line) {
    let testInterval = testInterval ?? TimeAmount.nanoseconds(time.nanoseconds / 5)
    let endTime = NIODeadline.now() + time

    repeat {
        if condition() { return }
        usleep(UInt32(testInterval.nanoseconds / 1000))
    } while (NIODeadline.now() < endTime)

    if !condition() {
        XCTFail(message, file: (file), line: line)
    }
}

func assertNoThrowWithValue<T>(_ body: @autoclosure () throws -> T, defaultValue: T? = nil, message: String? = nil, file: StaticString = #file, line: UInt = #line) throws -> T {
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
    let (fd, path) = openTemporaryFile()
    let fileHandle = NIOFileHandle(descriptor: fd)
    defer {
        XCTAssertNoThrow(try fileHandle.close())
        XCTAssertEqual(0, unlink(path))
    }
    if let content = content {
        let fileDesciptor = FileDescriptor(rawValue: fd)
        try fileDesciptor.writeAll(content.utf8)
        XCTAssertEqual(try fileDesciptor.seek(offset: 0, from: .start), 0)
    }
    return try body(fileHandle, path)
}

fileprivate var temporaryDirectory: String {
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
#endif // os
#endif // targetEnvironment
    }
}

func openTemporaryFile() -> (CInt, String) {
    let template = "\(temporaryDirectory)/nio_XXXXXX"
    var templateBytes = template.utf8 + [0]
    let templateBytesCount = templateBytes.count
    let fd = templateBytes.withUnsafeMutableBufferPointer { ptr in
        ptr.baseAddress!.withMemoryRebound(to: Int8.self, capacity: templateBytesCount) { (ptr: UnsafeMutablePointer<Int8>) in
            return mkstemp(ptr)
        }
    }
    templateBytes.removeLast()
    return (fd, String(decoding: templateBytes, as: Unicode.UTF8.self))
}
