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

let multiSanCert = """
-----BEGIN CERTIFICATE-----
MIIDEzCCAfugAwIBAgIURiMaUmhI1Xr0mZ4p+JmI0XjZTaIwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTE3MTAzMDEyMDUwMFoXDTQwMDEw
MTAwMDAwMFowFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF
AAOCAQ8AMIIBCgKCAQEA26DcKAxqdWivhS/J3Klf+cEnrT2cDzLhmVRCHuQZXiIr
tqr5401KDbRTVOg8v2qIyd8x4+YbpE47JP3fBrcMey70UK/Er8nu28RY3z7gZLLi
Yf+obHdDFCK5JaCGmM61I0c0vp7aMXsyv7h3vjEzTuBMlKR8p37ftaXSUAe3Qk/D
/fzA3k02E2e3ap0Sapd/wUu/0n/MFyy9HkkeykivAzLaaFhhvp3hATdFYC4FLld8
OMB60bC2S13CAljpMlpjU/XLLOUbaPgnNUqE1nFqFBoTl6kV6+ii8Dd5ENVvE7pE
SoNoyGLDUkDRJJMNUHAo0zbxyhd7WOtyZ7B4YBbPswIDAQABo10wWzBLBgNVHREE
RDBCgglsb2NhbGhvc3SCC2V4YW1wbGUuY29tgRB1c2VyQGV4YW1wbGUuY29thwTA
qAABhxAgAQ24AAAAAAAAAAAAAAABMAwGA1UdEwEB/wQCMAAwDQYJKoZIhvcNAQEL
BQADggEBACYBArIoL9ZzVX3M+WmTD5epmGEffrH7diRJZsfpVXi86brBPrbvpTBx
Fa+ZKxBAchPnWn4rxoWVJmTm4WYqZljek7oQKzidu88rMTbsxHA+/qyVPVlQ898I
hgnW4h3FFapKOFqq5Hj2gKKItFIcGoVY2oLTBFkyfAx0ofromGQp3fh58KlPhC0W
GX1nFCea74mGyq60X86aEWiyecYYj5AEcaDrTnGg3HLGTsD3mh8SUZPAda13rO4+
RGtGsA1C9Yovlu9a6pWLgephYJ73XYPmRIGgM64fkUbSuvXNJMYbWnzpoCdW6hka
IEaDUul/WnIkn/JZx8n+wgoWtyQa4EA=
-----END CERTIFICATE-----
"""

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

    func testEnumeratingSanFields() throws {
        var v4addr = in_addr()
        var v6addr = in6_addr()
        precondition(inet_pton(AF_INET, "192.168.0.1", &v4addr) == 1)
        precondition(inet_pton(AF_INET6, "2001:db8::1", &v6addr) == 1)

        let expectedSanFields: [OpenSSLCertificate.AlternativeName] = [
            .dnsName("localhost"),
            .dnsName("example.com"),
            .ipAddress(.ipv4(v4addr)),
            .ipAddress(.ipv6(v6addr)),
        ]
        let cert = try OpenSSLCertificate(buffer: [Int8](multiSanCert.utf8CString), format: .pem)
        let sans = [OpenSSLCertificate.AlternativeName](cert.subjectAlternativeNames()!)

        XCTAssertEqual(sans.count, expectedSanFields.count)
        for index in 0..<sans.count {
            switch (sans[index], expectedSanFields[index]) {
            case (.dnsName(let actualName), .dnsName(let expectedName)):
                XCTAssertEqual(actualName, expectedName)
            case (.ipAddress(.ipv4(var actualAddr)), .ipAddress(.ipv4(var expectedAddr))):
                XCTAssertEqual(memcmp(&actualAddr, &expectedAddr, MemoryLayout<in_addr>.size), 0)
            case (.ipAddress(.ipv6(var actualAddr)), .ipAddress(.ipv6(var expectedAddr))):
                XCTAssertEqual(memcmp(&actualAddr, &expectedAddr, MemoryLayout<in6_addr>.size), 0)
            default:
                XCTFail("Invalid entry in sans.")
            }
        }
    }

    func testNonexistentSan() throws {
        let cert = try OpenSSLCertificate(buffer: [Int8](samplePemCert.utf8CString), format: .pem)
        XCTAssertNil(cert.subjectAlternativeNames())
    }
}
