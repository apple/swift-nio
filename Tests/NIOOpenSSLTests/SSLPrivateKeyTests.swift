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
import XCTest
@testable import NIO
@testable import NIOOpenSSL

class SSLPrivateKeyTest: XCTestCase {
    static var pemKeyFilePath: String! = nil
    static var derKeyFilePath: String! = nil
    static var dynamicallyGeneratedKey: OpenSSLPrivateKey! = nil

    override class func setUp() {
        SSLPrivateKeyTest.pemKeyFilePath = try! dumpToFile(text: samplePemKey)
        SSLPrivateKeyTest.derKeyFilePath = try! dumpToFile(data: sampleDerKey)

        let (_, key) = generateSelfSignedCert()
        SSLPrivateKeyTest.dynamicallyGeneratedKey = key
    }

    override class func tearDown() {
        _ = SSLPrivateKeyTest.pemKeyFilePath.withCString {
            unlink($0)
        }
        _ = SSLPrivateKeyTest.derKeyFilePath.withCString {
            unlink($0)
        }
    }

    func testLoadingPemKeyFromFile() throws {
        let key1 = try OpenSSLPrivateKey(file: SSLPrivateKeyTest.pemKeyFilePath, format: .pem)
        let key2 = try OpenSSLPrivateKey(file: SSLPrivateKeyTest.pemKeyFilePath, format: .pem)

        XCTAssertEqual(key1, key2)
        XCTAssertNotEqual(key1, SSLPrivateKeyTest.dynamicallyGeneratedKey)
    }

    func testLoadingDerKeyFromFile() throws {
        let key1 = try OpenSSLPrivateKey(file: SSLPrivateKeyTest.derKeyFilePath, format: .der)
        let key2 = try OpenSSLPrivateKey(file: SSLPrivateKeyTest.derKeyFilePath, format: .der)

        XCTAssertEqual(key1, key2)
        XCTAssertNotEqual(key1, SSLPrivateKeyTest.dynamicallyGeneratedKey)
    }

    func testDerAndPemAreIdentical() throws {
        let key1 = try OpenSSLPrivateKey(file: SSLPrivateKeyTest.pemKeyFilePath, format: .pem)
        let key2 = try OpenSSLPrivateKey(file: SSLPrivateKeyTest.derKeyFilePath, format: .der)

        XCTAssertEqual(key1, key2)
    }

    func testLoadingPemKeyFromMemory() throws {
        let key1 = try OpenSSLPrivateKey(buffer: [Int8](samplePemKey.utf8CString), format: .pem)
        let key2 = try OpenSSLPrivateKey(buffer: [Int8](samplePemKey.utf8CString), format: .pem)

        XCTAssertEqual(key1, key2)
    }

    func testLoadingDerKeyFromMemory() throws {
        let keyBuffer = sampleDerKey.asArray()
        let key1 = try OpenSSLPrivateKey(buffer: keyBuffer, format: .der)
        let key2 = try OpenSSLPrivateKey(buffer: keyBuffer, format: .der)

        XCTAssertEqual(key1, key2)
    }

    func testLoadingGibberishFromMemoryAsPemFails() throws {
        let keyBuffer: [Int8] = [1, 2, 3]

        do {
            _ = try OpenSSLPrivateKey(buffer: keyBuffer, format: .pem)
            XCTFail("Gibberish successfully loaded")
        } catch NIOOpenSSLError.failedToLoadPrivateKey {
            // Do nothing.
        }
    }

    func testLoadingGibberishFromMemoryAsDerFails() throws {
        let keyBuffer: [Int8] = [1, 2, 3]

        do {
            _ = try OpenSSLPrivateKey(buffer: keyBuffer, format: .der)
            XCTFail("Gibberish successfully loaded")
        } catch NIOOpenSSLError.failedToLoadPrivateKey {
            // Do nothing.
        }
    }

    func testLoadingGibberishFromFileAsPemFails() throws {
        let tempFile = try dumpToFile(text: "hello")
        defer {
            _ = tempFile.withCString { unlink($0) }
        }

        do {
            _ = try OpenSSLPrivateKey(file: tempFile, format: .pem)
            XCTFail("Gibberish successfully loaded")
        } catch NIOOpenSSLError.failedToLoadPrivateKey {
            // Do nothing.
        }
    }

    func testLoadingGibberishFromFileAsDerFails() throws {
        let tempFile = try dumpToFile(text: "hello")
        defer {
            _ = tempFile.withCString { unlink($0) }
        }

        do {
            _ = try OpenSSLPrivateKey(file: tempFile, format: .der)
            XCTFail("Gibberish successfully loaded")
        } catch NIOOpenSSLError.failedToLoadPrivateKey {
            // Do nothing.
        }
    }
}
