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

private func makeTemporaryFile() -> String {
    let template = "/tmp/niotestXXXXXXX"
    var templateBytes = Array(template.utf8)
    templateBytes.append(0)
    _ = templateBytes.withUnsafeMutableBufferPointer { ptr in
        ptr.baseAddress!.withMemoryRebound(to: Int8.self, capacity: templateBytes.count) { (ptr: UnsafeMutablePointer<Int8>) in
            return mktemp(ptr)
        }
    }
    templateBytes.removeLast()
    return String(decoding: templateBytes, as: UTF8.self)
}

internal func dumpToFile(data: Data) throws  -> String {
    let filename = makeTemporaryFile()
    try data.write(to: URL(fileURLWithPath: filename))
    return filename
}

internal func dumpToFile(text: String) throws -> String {
    return try dumpToFile(data: text.data(using: .utf8)!)
}

internal extension Data {
    func asArray() -> [Int8] {
        return self.withUnsafeBytes { (dataPtr: UnsafePointer<UInt8>) -> [Int8] in
            return dataPtr.withMemoryRebound(to: Int8.self, capacity: self.count) { reboundPtr in
                let tempBuffer = UnsafeBufferPointer(start: reboundPtr, count: self.count)
                return [Int8](tempBuffer)
            }
        }
    }
}

class SSLCertificateTest: XCTestCase {
    static var pemCertFilePath: String! = nil
    static var derCertFilePath: String! = nil
    static var dynamicallyGeneratedCert: OpenSSLCertificate! = nil

    override class func setUp() {
        SSLCertificateTest.pemCertFilePath = try! dumpToFile(text: samplePemCert)
        SSLCertificateTest.derCertFilePath = try! dumpToFile(data: sampleDerCert)

        let (cert, _) = generateSelfSignedCert()
        SSLCertificateTest.dynamicallyGeneratedCert = cert
    }

    override class func tearDown() {
        _ = SSLCertificateTest.pemCertFilePath.withCString {
            unlink($0)
        }
        _ = SSLCertificateTest.derCertFilePath.withCString {
            unlink($0)
        }
    }

    func testLoadingPemCertFromFile() throws {
        let cert1 = try OpenSSLCertificate(file: SSLCertificateTest.pemCertFilePath, format: .pem)
        let cert2 = try OpenSSLCertificate(file: SSLCertificateTest.pemCertFilePath, format: .pem)

        XCTAssertEqual(cert1, cert2)
        XCTAssertNotEqual(cert1, SSLCertificateTest.dynamicallyGeneratedCert)
    }

    func testLoadingDerCertFromFile() throws {
        let cert1 = try OpenSSLCertificate(file: SSLCertificateTest.derCertFilePath, format: .der)
        let cert2 = try OpenSSLCertificate(file: SSLCertificateTest.derCertFilePath, format: .der)

        XCTAssertEqual(cert1, cert2)
        XCTAssertNotEqual(cert1, SSLCertificateTest.dynamicallyGeneratedCert)
    }

    func testDerAndPemAreIdentical() throws {
        let cert1 = try OpenSSLCertificate(file: SSLCertificateTest.pemCertFilePath, format: .pem)
        let cert2 = try OpenSSLCertificate(file: SSLCertificateTest.derCertFilePath, format: .der)

        XCTAssertEqual(cert1, cert2)
    }

    func testLoadingPemCertFromMemory() throws {
        let cert1 = try OpenSSLCertificate(buffer: [Int8](samplePemCert.utf8CString), format: .pem)
        let cert2 = try OpenSSLCertificate(buffer: [Int8](samplePemCert.utf8CString), format: .pem)

        XCTAssertEqual(cert1, cert2)
    }

    func testLoadingDerCertFromMemory() throws {
        let certBuffer = sampleDerCert.asArray()
        let cert1 = try OpenSSLCertificate(buffer: certBuffer, format: .der)
        let cert2 = try OpenSSLCertificate(buffer: certBuffer, format: .der)

        XCTAssertEqual(cert1, cert2)
    }

    func testLoadingGibberishFromMemoryAsPemFails() throws {
        let keyBuffer: [Int8] = [1, 2, 3]

        do {
            _ = try OpenSSLCertificate(buffer: keyBuffer, format: .pem)
            XCTFail("Gibberish successfully loaded")
        } catch NIOOpenSSLError.failedToLoadCertificate {
            // Do nothing.
        }
    }

    func testLoadingGibberishFromMemoryAsDerFails() throws {
        let keyBuffer: [Int8] = [1, 2, 3]

        do {
            _ = try OpenSSLCertificate(buffer: keyBuffer, format: .der)
            XCTFail("Gibberish successfully loaded")
        } catch NIOOpenSSLError.failedToLoadCertificate {
            // Do nothing.
        }
    }

    func testLoadingGibberishFromFileAsPemFails() throws {
        let tempFile = try dumpToFile(text: "hello")
        defer {
            _ = tempFile.withCString { unlink($0) }
        }

        do {
            _ = try OpenSSLCertificate(file: tempFile, format: .pem)
            XCTFail("Gibberish successfully loaded")
        } catch NIOOpenSSLError.failedToLoadCertificate {
            // Do nothing.
        }
    }

    func testLoadingGibberishFromFileAsDerFails() throws {
        let tempFile = try dumpToFile(text: "hello")
        defer {
            _ = tempFile.withCString { unlink($0) }
        }

        do {
            _ = try OpenSSLCertificate(file: tempFile, format: .der)
            XCTFail("Gibberish successfully loaded")
        } catch NIOOpenSSLError.failedToLoadCertificate {
            // Do nothing.
        }
    }
}
