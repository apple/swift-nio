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

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux) || os(Android)
import _NIOFileSystem
import _NIOFileSystemFoundationCompat
import XCTest

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension FileSystem {
    func temporaryFilePath(
        _ function: String = #function,
        inTemporaryDirectory: Bool = true
    ) async throws -> FilePath {
        if inTemporaryDirectory {
            let directory = try await self.temporaryDirectory
            return self.temporaryFilePath(function, inDirectory: directory)
        } else {
            return self.temporaryFilePath(function, inDirectory: nil)
        }
    }

    func temporaryFilePath(
        _ function: String = #function,
        inDirectory directory: FilePath?
    ) -> FilePath {
        let index = function.firstIndex(of: "(")!
        let functionName = function.prefix(upTo: index)
        let random = UInt32.random(in: .min ... .max)
        let fileName = "\(functionName)-\(random)"

        if let directory = directory {
            return directory.appending(fileName)
        } else {
            return FilePath(fileName)
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class FileSystemBytesConformanceTests: XCTestCase {
    func testTimepecToDate() async throws {
        XCTAssertEqual(
            FileInfo.Timespec(seconds: 0, nanoseconds: 0).date,
            Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(
            FileInfo.Timespec(seconds: 1, nanoseconds: 0).date,
            Date(timeIntervalSince1970: 1)
        )
        XCTAssertEqual(
            FileInfo.Timespec(seconds: 1, nanoseconds: 1).date,
            Date(timeIntervalSince1970: 1.000000001)
        )
    }

    func testReadFileIntoData() async throws {
        let fs = FileSystem.shared
        let path = try await fs.temporaryFilePath()

        try await fs.withFileHandle(forReadingAndWritingAt: path) { fileHandle in
            _ = try await fileHandle.write(contentsOf: [0, 1, 2], toAbsoluteOffset: 0)
        }

        let contents = try await Data(contentsOf: path, maximumSizeAllowed: .bytes(1024))

        XCTAssertEqual(contents, Data([0, 1, 2]))
    }
}
#endif
