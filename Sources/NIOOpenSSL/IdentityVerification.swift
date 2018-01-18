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

import NIO

private let ASCII_PERIOD: UInt8 = ".".utf8.first!
private let ASCII_ASTERISK: UInt8 = "*".utf8.first!
private let ASCII_IDN_A_IDENTIFIER: [UInt8] = Array("xn--".utf8)
private let ASCII_CAPITAL_A: UInt8 = 65
private let ASCII_CAPITAL_Z: UInt8 = 90
private let ASCII_CASE_DISTANCE: UInt8 = 32

typealias SliceType = RandomAccessSlice

/// We need these extra methods defining equality.
private extension SliceType where Base == UnsafeBufferPointer<UInt8> {
    static func ==(lhs: SliceType<Base>, rhs: SliceType<Base>) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }

        return memcmp(lhs.base.baseAddress!.advanced(by: lhs.startIndex),
                      rhs.base.baseAddress!.advanced(by: rhs.startIndex),
                      lhs.count) == 0
    }

    static func ==(lhs: SliceType<Base>, rhs: [UInt8]) -> Bool {
        return rhs.withUnsafeBufferPointer {
            return lhs == $0[...]
        }
    }

    static func !=(lhs: SliceType<Base>, rhs: [UInt8]) -> Bool {
        return !(lhs == rhs)
    }
}

private extension String {
    /// Calls `fn` with an `UnsafeBufferPointer<UInt8>` pointing to a
    /// non-NULL-terminated sequence of ASCII bytes. If the string this method
    /// is called on contains non-ACSII code points, this method throws.
    ///
    /// This method exists to avoid doing repeated loops over the string buffer.
    /// In a naive implementation we'd loop at least three times: once to lowercase
    /// the string, once to get a buffer pointer to a contiguous buffer, and once
    /// to confirm the string is ASCII. Here we can do that all in one loop.
    func withLowercaseASCIIBuffer<T>(_ fn: (UnsafeBufferPointer<UInt8>) throws -> T) throws -> T {
        let asciiCapitals = ASCII_CAPITAL_A...ASCII_CAPITAL_Z
        var buffer = [UInt8]()
        buffer.reserveCapacity(self.utf8.count)

        for codeUnit in self.utf8 {
            guard codeUnit < 128 else {
                throw NIOOpenSSLError.cannotMatchULabel
            }

            if asciiCapitals.contains(codeUnit) {
                buffer.append(codeUnit + ASCII_CASE_DISTANCE)
            } else {
                buffer.append(codeUnit)
            }
        }

        return try buffer.withUnsafeBufferPointer {
            try fn($0)
        }
    }
}

/// Validates that a given leaf certificate is valid for a service.
///
/// This function implements the logic for service validation as specified by
/// RFC 6125 (https://tools.ietf.org/search/rfc6125), which loosely speaking
/// defines the common algorithm used for validating that an X.509 certificate
/// is valid for a given service
///
/// It is extremely frustrating that we need to validate this, given that in a
/// sensible world OpenSSL would do it for us. Sadly, it does not always have
/// access to the functions to do this: in particular, OpenSSL versions before
/// 1.0.2, and all LibreSSL versions, do not include this code. So we are forced
/// by necessity to write it ourselves.
///
/// This is extremely dangerous code: logic errors in this function or any function
/// that it calls potentially allow for us to accept X.509 certificates that we
/// should reject. Even having this code in the codebase is a massive liability, and
/// as soon as it is practically possible we should aim to remove it and rely on a
/// more trustworthy implementation.
///
/// The algorithm we're implementing is specified in RFC 6125 Section 6 if you want to
/// follow along at home.
internal func validIdentityForService(serverHostname: String?,
                                      socketAddress: SocketAddress,
                                      leafCertificate: OpenSSLCertificate) throws -> Bool {
    if let serverHostname = serverHostname {
        return try serverHostname.withLowercaseASCIIBuffer {
            try validIdentityForService(serverHostname: $0,
                                               socketAddress: socketAddress,
                                               leafCertificate: leafCertificate)
        }
    } else {
        return try validIdentityForService(serverHostname: nil as UnsafeBufferPointer<UInt8>?,
                                           socketAddress: socketAddress,
                                           leafCertificate: leafCertificate)
    }
}

private func validIdentityForService(serverHostname: UnsafeBufferPointer<UInt8>?,
                                     socketAddress: SocketAddress,
                                     leafCertificate: OpenSSLCertificate) throws -> Bool {
    // Step 1 is to ensure that the user's domain name has any IDN U-labels transformed
    // into IDN A-labels.


    // We want to begin by checking the subjectAlternativeName fields. If there are any fields
    // in there that we could validate against (either IP or hostname) we will validate against
    // them, and then refuse to check the commonName field. If there are no SAN fields to
    // validate against, we'll check commonName.
    var checkedMatch = false
    if let alternativeNames = leafCertificate.subjectAlternativeNames() {
        for name in alternativeNames {
            checkedMatch = true

            switch name {
            case .dnsName(let dnsName):
                let matchedHostname = dnsName.withUnsafeBufferPointer {
                    matchHostname(serverHostname: serverHostname, dnsName: $0)
                }
                if matchedHostname {
                    return true
                }
            case .ipAddress(let ip):
                if matchIpAddress(socketAddress: socketAddress, certificateIP: ip) {
                    return true
                }
            }
        }
    }

    guard !checkedMatch else {
        // We had some subject alternative names, but none matched. We failed here.
        return false
    }

    // In the absence of any matchable subjectAlternativeNames, we can fall back to checking
    // the common name. This is a deprecated practice, and in a future release we should
    // stop doing this.
    guard let commonName = leafCertificate.commonName() else {
        // No CN, no match.
        return false
    }

    // We have a common name. Let's check it against the provided hostname. We never check
    // the common name against the IP address.
    return commonName.withUnsafeBufferPointer {
        matchHostname(serverHostname: serverHostname, dnsName: $0)
    }
}

private func matchHostname(serverHostname: UnsafeBufferPointer<UInt8>?, dnsName: UnsafeBufferPointer<UInt8>) -> Bool {
    guard let serverHostname = serverHostname else {
        // No server hostname was provided, so we cannot match.
        return false
    }
    var ourHostname = serverHostname[...]
    var certHostname = dnsName[...]

    // A quick sanity check before we begin: both names need to be entirely-ASCII.
    // If the one provided by the server isn't entirely-ASCII, then
    // we should refuse to match it. Additionally, the server-provided name must not contain embedded NULL
    // bytes. Our own hostname will have passed through our own code to be lowercased, so we just have
    // an assertion here to catch programming errors in debug code.
    assert(ourHostname.lazy.filter { (c: UInt8) -> Bool in c > 127 }.count == 0)
    if (certHostname.lazy.filter { (c: UInt8) -> Bool in (c > 127) || (c == 0) }.count) > 0 {
        return false  // No match
    }

    // First, strip trailing dots from the hostnames.
    if ourHostname.last == .some(ASCII_PERIOD) {
        ourHostname = ourHostname.dropLast()
    }
    if certHostname.last == .some(ASCII_PERIOD) {
        certHostname = certHostname.dropLast()
    }

    // Next, check if there is a wildcard, and how many there are.
    let wildcardCount = certHostname.lazy.filter { $0 == ASCII_ASTERISK }.count
    switch wildcardCount {
    case 0:
        // No wildcard means these are just a direct case-insensitive string match.
        return ourHostname == certHostname
    case 1:
        // One wildcard is ok.
        break
    default:
        // More than one wildcard is invalid, we should refuse to match.
        return false
    }

    // Some sanity checking now. The wildcard must be in the left-most label in
    // the name. That name must not be part of an IDN A-label. The name must contain
    // at least two labels. We want to validate that all of this is correct.
    let certComponents = certHostname.split(separator: ASCII_PERIOD, maxSplits: 1, omittingEmptySubsequences: false)
    guard certComponents.count == 2 else {
        // Insufficiently many labels.
        return false
    }
    guard certComponents[0].contains(ASCII_ASTERISK) else {
        // The wildcard is in a middle portion, we don't accept that.
        return false
    }
    guard certComponents[0].prefix(4) != ASCII_IDN_A_IDENTIFIER else {
        // This is an IDN A-label, it may not have a wildcard.
        return false
    }

    // Ok, better. We know what's happening now. We need both hostnames split into components.
    let hostnameComponents = ourHostname.split(separator: ASCII_PERIOD, maxSplits: 1, omittingEmptySubsequences: false)
    guard hostnameComponents.count == 2 else {
        // Different numbers of labels, these cannot match.
        return false
    }

    guard wildcardLabelMatch(wildcard: certComponents[0], target: hostnameComponents[0]) else {
        return false
    }

    // Cool, the wildcard is ok. The rest should just be a straightforward match.
    return certComponents[1] == hostnameComponents[1]
}

private func matchIpAddress(socketAddress: SocketAddress, certificateIP: OpenSSLCertificate.IPAddress) -> Bool {
    // These match if the two underlying IP address structures match.
    switch (socketAddress, certificateIP) {
    case (.v4(let sockaddr, _), .ipv4(var addr2)):
        var addr1 = sockaddr.sin_addr
        return memcmp(&addr1, &addr2, MemoryLayout<in_addr>.size) == 0
    case (.v6(let sockaddr, _), .ipv6(var addr2)):
        var addr1 = sockaddr.sin6_addr
        return memcmp(&addr1, &addr2, MemoryLayout<in6_addr>.size) == 0
    default:
        // Different protocol families, no match.
        return false
    }
}

private func wildcardLabelMatch(wildcard: SliceType<UnsafeBufferPointer<UInt8>>,
                                target: SliceType<UnsafeBufferPointer<UInt8>>) -> Bool {
    // The wildcard can appear more-or-less anywhere in the first label. The wildcard
    // character itself can match any number of characters, though it must match at least
    // one.
    // The algorithm for this is simple: first we check that target is at least the same
    // size as wildcard. Then we split wildcard on the wildcard character and confirm that
    // the characters *before* the wildcard are the prefix of target, and that the
    // characters *after* the wildcard are the suffix of target. This works well because
    // the empty string is a prefix and suffix of all strings.
    guard target.count >= wildcard.count else {
        // The target label cannot possibly match the wildcard.
        return false
    }

    let components = wildcard.split(separator: ASCII_ASTERISK, maxSplits: 1, omittingEmptySubsequences: false)
    precondition(components.count == 2)
    return target.prefix(components[0].count) == components[0] && target.suffix(components[1].count) == components[1]
}

