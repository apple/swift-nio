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
import NIO
@testable import NIOOpenSSL

/// This cert contains the following SAN fields:
/// DNS:*.wildcard.example.com - A straightforward wildcard, should be accepted
/// DNS:fo*.example.com - A suffix wildcard, should be accepted
/// DNS:*ar.example.com - A prefix wildcard, should be accepted
/// DNS:b*z.example.com - An infix wildcard
/// DNS:trailing.period.example.com. - A domain with a trailing period, should match
/// DNS:xn--strae-oqa.unicode.example.com. - An IDN A-label, should match.
/// DNS:xn--x*-gia.unicode.example.com. - An IDN A-label with a wildcard, invalid.
/// DNS:weirdwildcard.*.example.com. - A wildcard not in the leftmost label, invalid.
/// DNS:*.*.double.example.com. - Two wildcards, invalid.
/// DNS:*.xn--strae-oqa.example.com. - A wildcard followed by a new IDN A-label, this is fine.
/// A SAN with a null in it, should be ignored.
///
/// This also contains a commonName of httpbin.org.
///
/// Note that to get the NULL into the SAN I needed to edit it by hand, so this cert has
/// an invalid signature. Don't worry about it: it doesn't affect these tests.
private let weirdoPEMCert = """
-----BEGIN CERTIFICATE-----
MIID9TCCAt2gAwIBAgIUK5EI2ZoG1RLBWJ142HK7vjC9plQwDQYJKoZIhvcNAQEL
BQAwFjEUMBIGA1UEAwwLaHR0cGJpbi5vcmcwHhcNMTcxMTAyMTExNjUzWhcNNDAw
MTAxMDAwMDAwWjAWMRQwEgYDVQQDDAtodHRwYmluLm9yZzCCASIwDQYJKoZIhvcN
AQEBBQADggEPADCCAQoCggEBAOYuPFg8hmACy7UL9mxbnkd4+kYGoDFNUi34tSHG
8pGsV+1ZgJH0+p6+DcEVFTRTjG4jmiQHxVV8Uu82u8pvc4Ol/+kGXgIsmkSUOan6
cYNsVJ5W5ZuQe7spL4dilyFPOi7hcP2OgG29NBIYnf4LUlznMF/G1wdKAhAAqeRr
u5HQK/VDw6G85ycxbcaevV6jUd2sslcqMrh4MXP9txZwUdLfXFEP3r0yGhQP48Wm
1NjCG82U1YpykrWGQYqYMXun3/9xVPoy3k+teRHBCcHhIi6qy7V9JDa+STzEzkbh
7JUCUEHz4zJJ6vc1598UcQNW/aTtKeshuyX6NFpvrmkcwv0CAwEAAaOCATkwggE1
MIIBIwYDVR0RBIIBGjCCARaCFioud2lsZGNhcmQuZXhhbXBsZS5jb22CD2ZvKi5l
eGFtcGxlLmNvbYIPKmFyLmV4YW1wbGUuY29tgg9iKnouZXhhbXBsZS5jb22CHHRy
YWlsaW5nLnBlcmlvZC5leGFtcGxlLmNvbS6CInhuLS1zdHJhZS1vcWEudW5pY29k
ZS5leGFtcGxlLmNvbS6CH3huLS14Ki1naWEudW5pY29kZS5leGFtcGxlLmNvbS6C
HHdlaXJkd2lsZGNhcmQuKi5leGFtcGxlLmNvbS6CFyouKi5kb3VibGUuZXhhbXBs
ZS5jb20ughwqLnhuLS1zdHJhZS1vcWEuZXhhbXBsZS5jb20ughFudWwAbC5leGFt
cGxlLmNvbTAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4IBAQBoNHwL0Lix
mtPoxFDA8w/5nF/hP/O+iQKYpR18gLqVZ2gmKgpSVwXZQB9891SKe1RYD8U1zsyt
YbV45wSp3kdBvH6uu26fC2btiXasfiFCieZqyNnqDy1PhPHiVldddeksvf0D1hsk
VwdBkqe3U47vRALvAWk9VVLYBtQuX4kkY4nEM4N+Dt0qW/8ZdIkLlD9pjTY2WC1G
L+KFdw92R9DCEqE0nOUxU85D8Sfsoi19nx2LwhtCA40kuQNUZcW5ZElJ0kwxvd1Z
6FhTJ0ACxsfKo3kS4Z4Zz4aib8D1gRdUrK2oKPFRIzwaoYuJw4gez+aSMqaGReSt
rwIUx8hwcI3A
-----END CERTIFICATE-----
"""

/// Returns whether this system supports resolving IPv6 function.
func ipv6Supported() throws -> Bool {
    do {
        _ = try SocketAddress.newAddressResolving(host: "2001:db8::1", port: 443)
        return true
    } catch SocketAddressError.unknown {
        return false
    }
}

class IdentityVerificationTest: XCTestCase {
    func testCanValidateHostnameInFirstSan() throws {
        let cert = try OpenSSLCertificate(buffer: [Int8](multiSanCert.utf8CString), format: .pem)
        let matched = try validIdentityForService(serverHostname: "localhost",
                                                  socketAddress: try .unixDomainSocketAddress(path: "/path"),
                                                  leafCertificate: cert)
        XCTAssertTrue(matched)
    }

    func testCanValidateHostnameInSecondSan() throws {
        let cert = try OpenSSLCertificate(buffer: [Int8](multiSanCert.utf8CString), format: .pem)
        let matched = try validIdentityForService(serverHostname: "example.com",
                                                  socketAddress: try .unixDomainSocketAddress(path: "/path"),
                                                  leafCertificate: cert)
        XCTAssertTrue(matched)
    }

    func testIgnoresTrailingPeriod() throws {
        let cert = try OpenSSLCertificate(buffer: [Int8](multiSanCert.utf8CString), format: .pem)
        let matched = try validIdentityForService(serverHostname: "example.com.",
                                                  socketAddress: try .unixDomainSocketAddress(path: "/path"),
                                                  leafCertificate: cert)
        XCTAssertTrue(matched)
    }

    func testLowercasesHostnameForSan() throws {
        let cert = try OpenSSLCertificate(buffer: [Int8](multiSanCert.utf8CString), format: .pem)
        let matched = try validIdentityForService(serverHostname: "LoCaLhOsT",
                                                  socketAddress: try .unixDomainSocketAddress(path: "/path"),
                                                  leafCertificate: cert)
        XCTAssertTrue(matched)
    }

    func testRejectsIncorrectHostname() throws {
        let cert = try OpenSSLCertificate(buffer: [Int8](multiSanCert.utf8CString), format: .pem)
        let matched = try validIdentityForService(serverHostname: "httpbin.org",
                                                  socketAddress: try .unixDomainSocketAddress(path: "/path"),
                                                  leafCertificate: cert)
        XCTAssertFalse(matched)
    }

    func testAcceptsIpv4Address() throws {
        let cert = try OpenSSLCertificate(buffer: [Int8](multiSanCert.utf8CString), format: .pem)
        let matched = try validIdentityForService(serverHostname: nil,
                                                  socketAddress: try .newAddressResolving(host: "192.168.0.1", port: 443),
                                                  leafCertificate: cert)
        XCTAssertTrue(matched)
    }


    func testAcceptsIpv6Address() throws {
        guard try ipv6Supported() else { return }
        let ipv6Address = try SocketAddress.newAddressResolving(host: "2001:db8::1", port: 443)

        let cert = try OpenSSLCertificate(buffer: [Int8](multiSanCert.utf8CString), format: .pem)
        let matched = try validIdentityForService(serverHostname: nil,
                                                  socketAddress: ipv6Address,
                                                  leafCertificate: cert)
        XCTAssertTrue(matched)
    }

    func testRejectsIncorrectIpv4Address() throws {
        let cert = try OpenSSLCertificate(buffer: [Int8](multiSanCert.utf8CString), format: .pem)
        let matched = try validIdentityForService(serverHostname: nil,
                                                  socketAddress: try .newAddressResolving(host: "192.168.0.2", port: 443),
                                                  leafCertificate: cert)
        XCTAssertFalse(matched)
    }

    func testRejectsIncorrectIpv6Address() throws {
        guard try ipv6Supported() else { return }
        let ipv6Address = try SocketAddress.newAddressResolving(host: "2001:db8::2", port: 443)

        let cert = try OpenSSLCertificate(buffer: [Int8](multiSanCert.utf8CString), format: .pem)
        let matched = try validIdentityForService(serverHostname: nil,
                                                  socketAddress: ipv6Address,
                                                  leafCertificate: cert)
        XCTAssertFalse(matched)
    }

    func testAcceptsWildcards() throws {
        let cert = try OpenSSLCertificate(buffer: [Int8](weirdoPEMCert.utf8CString), format: .pem)
        let matched = try validIdentityForService(serverHostname: "this.wildcard.example.com",
                                                  socketAddress: try .unixDomainSocketAddress(path: "/path"),
                                                  leafCertificate: cert)
        XCTAssertTrue(matched)
    }

    func testAcceptsSuffixWildcard() throws {
        let cert = try OpenSSLCertificate(buffer: [Int8](weirdoPEMCert.utf8CString), format: .pem)
        let matched = try validIdentityForService(serverHostname: "foo.example.com",
                                                  socketAddress: try .unixDomainSocketAddress(path: "/path"),
                                                  leafCertificate: cert)
        XCTAssertTrue(matched)
    }

    func testAcceptsPrefixWildcard() throws {
        let cert = try OpenSSLCertificate(buffer: [Int8](weirdoPEMCert.utf8CString), format: .pem)
        let matched = try validIdentityForService(serverHostname: "bar.example.com",
                                                  socketAddress: try .unixDomainSocketAddress(path: "/path"),
                                                  leafCertificate: cert)
        XCTAssertTrue(matched)
    }

    func testAcceptsInfixWildcard() throws {
        let cert = try OpenSSLCertificate(buffer: [Int8](weirdoPEMCert.utf8CString), format: .pem)
        let matched = try validIdentityForService(serverHostname: "baz.example.com",
                                                  socketAddress: try .unixDomainSocketAddress(path: "/path"),
                                                  leafCertificate: cert)
        XCTAssertTrue(matched)
    }

    func testIgnoresTrailingPeriodInCert() throws {
        let cert = try OpenSSLCertificate(buffer: [Int8](weirdoPEMCert.utf8CString), format: .pem)
        let matched = try validIdentityForService(serverHostname: "trailing.period.example.com",
                                                  socketAddress: try .unixDomainSocketAddress(path: "/path"),
                                                  leafCertificate: cert)
        XCTAssertTrue(matched)
    }

    func testRejectsEncodedIDNALabel() throws {
        let cert = try OpenSSLCertificate(buffer: [Int8](weirdoPEMCert.utf8CString), format: .pem)
        do {
            _ = try validIdentityForService(serverHostname: "straße.unicode.example.com",
                                            socketAddress: try .unixDomainSocketAddress(path: "/path"),
                                            leafCertificate: cert)
        } catch NIOOpenSSLError.cannotMatchULabel {
            return
        }

        XCTFail("Did not throw")
    }

    func testMatchesUnencodedIDNALabel() throws {
        let cert = try OpenSSLCertificate(buffer: [Int8](weirdoPEMCert.utf8CString), format: .pem)
        let matched = try validIdentityForService(serverHostname: "xn--strae-oqa.unicode.example.com",
                                                  socketAddress: try .unixDomainSocketAddress(path: "/path"),
                                                  leafCertificate: cert)
        XCTAssertTrue(matched)
    }

    func testDoesNotMatchIDNALabelWithWildcard() throws {
        let cert = try OpenSSLCertificate(buffer: [Int8](weirdoPEMCert.utf8CString), format: .pem)
        let matched = try validIdentityForService(serverHostname: "xn--xx-gia.unicode.example.com",
                                                  socketAddress: try .unixDomainSocketAddress(path: "/path"),
                                                  leafCertificate: cert)
        XCTAssertFalse(matched)
    }

    func testDoesNotMatchNonLeftmostWildcards() throws {
        let cert = try OpenSSLCertificate(buffer: [Int8](weirdoPEMCert.utf8CString), format: .pem)
        let matched = try validIdentityForService(serverHostname: "weirdwildcard.nomatch.example.com",
                                                  socketAddress: try .unixDomainSocketAddress(path: "/path"),
                                                  leafCertificate: cert)
        XCTAssertFalse(matched)
    }

    func testDoesNotMatchMultipleWildcards() throws {
        let cert = try OpenSSLCertificate(buffer: [Int8](weirdoPEMCert.utf8CString), format: .pem)
        let matched = try validIdentityForService(serverHostname: "one.two.double.example.com",
                                                  socketAddress: try .unixDomainSocketAddress(path: "/path"),
                                                  leafCertificate: cert)
        XCTAssertFalse(matched)
    }

    func testRejectsWildcardBeforeUnencodedIDNALabel() throws {
        let cert = try OpenSSLCertificate(buffer: [Int8](weirdoPEMCert.utf8CString), format: .pem)
        do {
            _ = try validIdentityForService(serverHostname: "foo.straße.example.com",
                                            socketAddress: try .unixDomainSocketAddress(path: "/path"),
                                            leafCertificate: cert)
        } catch NIOOpenSSLError.cannotMatchULabel {
            return
        }

        XCTFail("Did not throw")
    }

    func testMatchesWildcardBeforeEncodedIDNALabel() throws {
        let cert = try OpenSSLCertificate(buffer: [Int8](weirdoPEMCert.utf8CString), format: .pem)
        let matched = try validIdentityForService(serverHostname: "foo.xn--strae-oqa.example.com",
                                                  socketAddress: try .unixDomainSocketAddress(path: "/path"),
                                                  leafCertificate: cert)
        XCTAssertTrue(matched)
    }

    func testDoesNotMatchSANWithEmbeddedNULL() throws {
        let cert = try OpenSSLCertificate(buffer: [Int8](weirdoPEMCert.utf8CString), format: .pem)
        let matched = try validIdentityForService(serverHostname: "nul\u{0000}l.example.com",
                                                  socketAddress: try .unixDomainSocketAddress(path: "/path"),
                                                  leafCertificate: cert)
        XCTAssertFalse(matched)
    }

    func testFallsBackToCommonName() throws {
        let cert = try OpenSSLCertificate(buffer: [Int8](multiCNCert.utf8CString), format: .pem)
        let matched = try validIdentityForService(serverHostname: "localhost",
                                                  socketAddress: try .unixDomainSocketAddress(path: "/path"),
                                                  leafCertificate: cert)
        XCTAssertTrue(matched)
    }

    func testLowercasesForCommonName() throws {
        let cert = try OpenSSLCertificate(buffer: [Int8](multiCNCert.utf8CString), format: .pem)
        let matched = try validIdentityForService(serverHostname: "LoCaLhOsT",
                                                  socketAddress: try .unixDomainSocketAddress(path: "/path"),
                                                  leafCertificate: cert)
        XCTAssertTrue(matched)
    }

    func testRejectsUnicodeCommonNameWithUnencodedIDNALabel() throws {
        let cert = try OpenSSLCertificate(buffer: [Int8](unicodeCNCert.utf8CString), format: .pem)
        do {
            _ = try validIdentityForService(serverHostname: "straße.org",
                                            socketAddress: try .unixDomainSocketAddress(path: "/path"),
                                            leafCertificate: cert)
        } catch NIOOpenSSLError.cannotMatchULabel {
            return
        }

        XCTFail("Did not throw" )
    }

    func testRejectsUnicodeCommonNameWithEncodedIDNALabel() throws {
        let cert = try OpenSSLCertificate(buffer: [Int8](unicodeCNCert.utf8CString), format: .pem)
        let matched = try validIdentityForService(serverHostname: "xn--strae-oqa.org",
                                                  socketAddress: try .unixDomainSocketAddress(path: "/path"),
                                                  leafCertificate: cert)
        XCTAssertFalse(matched)
    }

    func testHandlesMissingCommonName() throws {
        let cert = try OpenSSLCertificate(buffer: [Int8](noCNCert.utf8CString), format: .pem)
        let matched = try validIdentityForService(serverHostname: "localhost",
                                                  socketAddress: try .unixDomainSocketAddress(path: "/path"),
                                                  leafCertificate: cert)
        XCTAssertFalse(matched)
    }

    func testDoesNotFallBackToCNWithSans() throws {
        let cert = try OpenSSLCertificate(buffer: [Int8](weirdoPEMCert.utf8CString), format: .pem)
        let matched = try validIdentityForService(serverHostname: "httpbin.org",
                                                  socketAddress: try .unixDomainSocketAddress(path: "/path"),
                                                  leafCertificate: cert)
        XCTAssertFalse(matched)
    }
}
