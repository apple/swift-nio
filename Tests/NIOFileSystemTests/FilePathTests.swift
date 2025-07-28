//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import SystemPackage
import XCTest
@_spi(Testing) import _NIOFileSystem

#if canImport(System)
import System
#endif

final class FilePathTests: XCTestCase {
    /// Tests that the conversion of a SystemPackage.FilePath and a System.FilePath instance (both pointing to the same path) to a NIOFilePath instance results
    /// in the same underlying object.
    func testConversion() {
        let filePathNIO = NIOFilePath("/foo/bar")

        let filePathSystemPackage = SystemPackage.FilePath("/foo/bar")
        XCTAssertEqual(filePathNIO.underlying, filePathSystemPackage)

        // Initialize a NIOFilePath from the SystemPackage.FilePath instance
        let systemPackageFilePathConvertedToNIO = NIOFilePath(filePathSystemPackage)
        XCTAssertEqual(filePathNIO, systemPackageFilePathConvertedToNIO)

        #if canImport(System)
        let filePathSystem = System.FilePath("/foo/bar")
        let systemFilePathConvertedToNIO = NIOFilePath(filePathSystem)
        XCTAssertEqual(filePathNIO, systemFilePathConvertedToNIO)
        XCTAssertEqual(systemFilePathConvertedToNIO.underlying, filePathSystemPackage)
        #endif
    }

    /// Runs a series of path manipulations on a NIOFilePath instance and a SystemPackage.FilePath instance, and checks whether both instances lead to the
    /// same result after each manipulation.
    func testPathManipulationEquality(
        originalNormalizedPath: String,
        _ filePathNIO: inout NIOFilePath,
        _ filePathSP: inout SystemPackage.FilePath
    ) {
        filePathNIO.append("baz/..")
        filePathSP.append("baz/..")
        XCTAssertEqual(filePathNIO.underlying, filePathSP)
        XCTAssertEqual(filePathNIO.string, originalNormalizedPath + "/baz/..")

        filePathNIO.append("qux")
        filePathSP.append("qux")
        XCTAssertEqual(filePathNIO.underlying, filePathSP)
        XCTAssertEqual(filePathNIO.string, originalNormalizedPath + "/baz/../qux")

        filePathNIO.lexicallyNormalize()
        filePathSP.lexicallyNormalize()
        XCTAssertEqual(filePathNIO.underlying, filePathSP)
        XCTAssertEqual(filePathNIO.string, originalNormalizedPath + "/qux")
        XCTAssertTrue(filePathNIO.isLexicallyNormal)

        filePathNIO.removeLastComponent()
        filePathSP.removeLastComponent()
        XCTAssertEqual(filePathNIO.underlying, filePathSP)
        XCTAssertEqual(filePathNIO.string, originalNormalizedPath)

        filePathNIO.push("qux/quux")
        filePathSP.push("qux/quux")
        XCTAssertEqual(filePathNIO.underlying, filePathSP)
        XCTAssertEqual(filePathNIO.string, originalNormalizedPath + "/qux/quux")

        let subComponents = NIOFilePath("qux/quux").components
        let replacement = NIOFilePath("bar/baz").components
        filePathNIO.components.replace(subComponents, with: replacement)
        filePathSP.components.replace(subComponents.underlying, with: replacement.underlying)
        XCTAssertEqual(filePathNIO.underlying, filePathSP)
        XCTAssertEqual(filePathNIO.string, originalNormalizedPath + "/bar/baz")

        // Check that the root and all components of both instances are equal
        XCTAssertEqual(filePathNIO.root?.underlying, filePathSP.root)
        zip(filePathNIO.components, filePathSP.components).forEach { XCTAssertEqual($0.underlying, $1) }
    }

    func testPathManipulationEqualitySystemAndSystemPackage() {
        let originalPath = "/foo/bar"
        var filePathNIO = NIOFilePath(originalPath)
        var filePathSystemPackage = SystemPackage.FilePath(originalPath)
        testPathManipulationEquality(originalNormalizedPath: originalPath, &filePathNIO, &filePathSystemPackage)

        #if canImport(System)
        let filePathSystem = System.FilePath(originalPath)
        var converted = NIOFilePath(filePathSystem).underlying
        var filePathNIOAgain = NIOFilePath(originalPath)
        testPathManipulationEquality(originalNormalizedPath: originalPath, &filePathNIOAgain, &converted)
        #endif
    }

    func testComponentsConstruction() {
        // Create a NIOFilePath from a root and components
        let constructedNIOFilepath = NIOFilePath(root: "/", ["foo", "bar", "..", "baz"])
        XCTAssertEqual(constructedNIOFilepath, "/foo/bar/../baz")

        // Now create a SystemPackage.FilePath from the same root and components
        let filePathRootSP = SystemPackage.FilePath.Root("/")
        // Convert the SystemPackage.FilePath root and components to NIOFilePath ones
        let convertedRootSP = NIOFilePath.Root(filePathRootSP)
        let convertedComponentsSP = ["foo", "bar", "..", "baz"].map(NIOFilePath.Component.init)

        // Construct a NIOFilePath from the converted root and components, and check if the same result is obtained
        XCTAssertEqual(constructedNIOFilepath, NIOFilePath(root: convertedRootSP, convertedComponentsSP))

        #if canImport(System)
        // Now do the same, but with System.FilePath
        let filePathRootS = System.FilePath.Root("/")
        // Convert the SystemPackage.FilePath root and components to NIOFilePath ones
        let convertedRootS = NIOFilePath.Root(filePathRootS)
        let convertedComponentsS = ["foo", "bar", "..", "baz"].compactMap(NIOFilePath.Component.init)
        // Construct a NIOFilePath from the converted root and components, and check if the same result is obtained
        XCTAssertEqual(constructedNIOFilepath, NIOFilePath(root: convertedRootS, convertedComponentsS))
        #endif
    }
}
