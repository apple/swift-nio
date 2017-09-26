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
import OpenSSL


// This function generates a random number suitable for use in an X509
// serial field. This needs to be a positive number less than 2^159
// (such that it will fit into 20 ASN.1 bytes).
// This also needs to be portable across operating systems, and the easiest
// way to do that is to use either getentropy() or read from urandom. Sadly
// we need to support old Linuxes which may not possess getentropy as a syscall
// (and definitely don't support it in glibc), so we need to read from urandom.
// In the future we should just use getentropy and be happy.
func randomSerialNumber() -> ASN1_INTEGER {
    let bytesToRead = 20
    let fd = open("/dev/urandom", O_RDONLY)
    precondition(fd != -1)
    defer {
        close(fd)
    }

    var readBytes = Array.init(repeating: UInt8(0), count: bytesToRead)
    let readCount = readBytes.withUnsafeMutableBytes {
        return read(fd, $0.baseAddress, bytesToRead)
    }
    precondition(readCount == bytesToRead)

    // Our 20-byte number needs to be converted into an integer. This is
    // too big for Swift's numbers, but OpenSSL can handle it fine.
    var bn = BIGNUM()
    _ = readBytes.withUnsafeBufferPointer {
        BN_bin2bn($0.baseAddress, Int32($0.count), &bn)
    }

    // We want to bitshift this right by 1 bit to ensure it's smaller than
    // 2^159.
    var shiftedBN = bn
    BN_rshift1(&bn, &shiftedBN)

    // Now we can turn this into our ASN1_INTEGER.
    var asn1int = ASN1_INTEGER()
    BN_to_ASN1_INTEGER(&shiftedBN, &asn1int)

    return asn1int
}

func generateRSAPrivateKey() -> UnsafeMutablePointer<EVP_PKEY> {
    let pkey = EVP_PKEY_new()!
    let rsa = RSA_generate_key(Int32(2048), UInt(65537), nil, nil)!
    let assignRC = EVP_PKEY_assign(pkey, EVP_PKEY_RSA, rsa)
    
    precondition(assignRC == 1)
    return pkey
}

func addExtension(x509: UnsafeMutablePointer<X509>, nid: Int32, value: String) {
    var extensionContext = X509V3_CTX()
    
    X509V3_set_ctx(&extensionContext, x509, x509, nil, nil, 0)
    let ext = value.withCString { (pointer) in
        return X509V3_EXT_conf_nid(nil, &extensionContext, nid, UnsafeMutablePointer(mutating: pointer))
    }!
    X509_add_ext(x509, ext, -1)
    X509_EXTENSION_free(ext)
}

func generateSelfSignedCert() -> (UnsafeMutablePointer<X509>, UnsafeMutablePointer<EVP_PKEY>) {
    let pkey = generateRSAPrivateKey()
    let x = X509_new()!
    X509_set_version(x, 3)

    // NB: X509_set_serialNumber uses an internal copy of the ASN1_INTEGER, so this is
    // safe, there will be no use-after-free.
    var serial = randomSerialNumber()
    X509_set_serialNumber(x, &serial)
    
    let notBefore = ASN1_TIME_new()!
    var now = time_t()
    ASN1_TIME_set(notBefore, time(&now))
    X509_set_notBefore(x, notBefore)
    ASN1_TIME_free(notBefore)
    
    now += 60 * 60  // Give ourselves an hour
    let notAfter = ASN1_TIME_new()!
    ASN1_TIME_set(notAfter, time(&now))
    X509_set_notAfter(x, notAfter)
    ASN1_TIME_free(notAfter)
    
    X509_set_pubkey(x, pkey)
    
    let commonName = "localhost"
    let name = X509_get_subject_name(x)
    commonName.withCString { (pointer: UnsafePointer<Int8>) -> Void in
        pointer.withMemoryRebound(to: UInt8.self, capacity: commonName.lengthOfBytes(using: .utf8)) { (pointer: UnsafePointer<UInt8>) -> Void in
            X509_NAME_add_entry_by_NID(name,
                                       NID_commonName,
                                       MBSTRING_UTF8,
                                       UnsafeMutablePointer(mutating: pointer),
                                       Int32(commonName.lengthOfBytes(using: .utf8)),
                                       -1,
                                       0)
        }
    }
    X509_set_issuer_name(x, name)
    
    addExtension(x509: x, nid: NID_basic_constraints, value: "critical,CA:FALSE")
    addExtension(x509: x, nid: NID_subject_key_identifier, value: "hash")
    addExtension(x509: x, nid: NID_subject_alt_name, value: "DNS:localhost,IP:127.0.0.1")
    
    X509_sign(x, pkey, EVP_sha256())
    
    return (x, pkey)
}
