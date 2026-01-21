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

import NIOFS
import XCTest

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
func XCTAssertThrowsErrorAsync<R>(
    file: StaticString = #filePath,
    line: UInt = #line,
    expression: () async throws -> R,
    onError: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expression did not throw", file: file, line: line)
    } catch {
        onError(error)
    }
}

func XCTAssertThrowsFileSystemError<R>(
    _ expression: @autoclosure () throws -> R,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ onError: (FileSystemError) -> Void = { _ in }
) {
    XCTAssertThrowsError(try expression(), file: file, line: line) { error in
        if let fsError = error as? FileSystemError {
            onError(fsError)
        } else {
            XCTFail(
                "Expected 'FileSystemError' but found '\(type(of: error))'",
                file: file,
                line: line
            )
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
func XCTAssertThrowsFileSystemErrorAsync<R>(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ expression: () async throws -> R,
    onError: (FileSystemError) -> Void = { _ in }
) async {
    await XCTAssertThrowsErrorAsync(file: file, line: line, expression: expression) { error in
        if let fsError = error as? FileSystemError {
            onError(fsError)
        } else {
            XCTFail(
                "Expected 'FileSystemError' but found '\(type(of: error))'",
                file: file,
                line: line
            )
        }
    }
}

func XCTAssertNoThrowAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
    } catch {
        XCTFail("Expression did throw: \(error)", file: file, line: line)
    }
}
