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

#if os(macOS) || os(tvOS) || os(iOS)
    import Darwin
#else
    import Glibc
#endif
import CNIOOpenSSL
import NIO

public class OpenSSLCertificate {
    internal let ref: UnsafeMutablePointer<X509>

    internal enum AlternativeName {
        case dnsName(String)
        case ipAddress(IPAddress)
    }

    internal enum IPAddress {
        case ipv4(in_addr)
        case ipv6(in6_addr)
    }

    private init(withReference ref: UnsafeMutablePointer<X509>) {
        self.ref = ref
    }

    /// Create an OpenSSLCertificate from a file at a given path in either PEM or
    /// DER format.
    public convenience init (file: String, format: OpenSSLSerializationFormats) throws {
        let fileObject = file.withCString { filePtr in
            return fopen(filePtr, "rb")
        }
        defer {
            fclose(fileObject)
        }

        let x509: UnsafeMutablePointer<X509>?
        switch format {
        case .pem:
            x509 = PEM_read_X509(fileObject, nil, nil, nil)
        case .der:
            x509 = d2i_X509_fp(fileObject, nil)
        }

        guard x509 != nil else {
            throw NIOOpenSSLError.failedToLoadCertificate
        }

        self.init(withReference: x509!)
    }

    /// Create an OpenSSLCertificate from a buffer of bytes in either PEM or
    /// DER format.
    public convenience init (buffer: [Int8], format: OpenSSLSerializationFormats) throws  {
        let bio = buffer.withUnsafeBytes {
            return BIO_new_mem_buf(UnsafeMutableRawPointer(mutating: $0.baseAddress!), Int32($0.count))!
        }
        defer {
            BIO_free(bio)
        }

        let x509: UnsafeMutablePointer<X509>?
        switch format {
        case .pem:
            x509 = PEM_read_bio_X509(bio, nil, nil, nil)
        case .der:
            x509 = d2i_X509_bio(bio, nil)
        }

        guard x509 != nil else {
            throw NIOOpenSSLError.failedToLoadCertificate
        }

        self.init(withReference: x509!)
    }

    /// Create an OpenSSLCertificate wrapping a pointer into OpenSSL.
    ///
    /// This is a function that should be avoided as much as possible because it plays poorly with
    /// OpenSSL's reference-counted memory. This function does not increment the reference count for the X509
    /// object here, nor does it duplicate it: it just takes ownership of the copy here. This object
    /// **will** deallocate the underlying X509 object when deinited, and so if you need to keep that
    /// X509 object alive you should call X509_dup before passing the pointer here.
    ///
    /// In general, however, this function should be avoided in favour of one of the convenience
    /// initializers, which ensure that the lifetime of the X509 object is better-managed.
    static public func fromUnsafePointer(pointer: UnsafePointer<X509>) -> OpenSSLCertificate {
        return OpenSSLCertificate(withReference: UnsafeMutablePointer(mutating: pointer))
    }

    /// Get a sequence of the alternative names in the certificate.
    internal func subjectAlternativeNames() -> SubjectAltNameSequence? {
        guard let sanExtension = X509_get_ext_d2i(ref, NID_subject_alt_name, nil, nil) else {
            return nil
        }
        let sanNames = sanExtension.assumingMemoryBound(to: stack_st_GENERAL_NAME.self)
        return SubjectAltNameSequence(nameStack: sanNames)
    }

    deinit {
        X509_free(ref)
    }
}

extension OpenSSLCertificate: Equatable {
    public static func ==(lhs: OpenSSLCertificate, rhs: OpenSSLCertificate) -> Bool {
        return X509_cmp(lhs.ref, rhs.ref) == 0
    }
}

internal class SubjectAltNameSequence: Sequence, IteratorProtocol {
    typealias Element = OpenSSLCertificate.AlternativeName

    private let nameStack: UnsafeMutablePointer<stack_st_GENERAL_NAME>
    private var nextIdx: Int32
    private let stackSize: Int32

    init(nameStack: UnsafeMutablePointer<stack_st_GENERAL_NAME>) {
        self.nameStack = nameStack
        self.stackSize = CNIOOpenSSL_sk_GENERAL_NAME_num(nameStack)
        self.nextIdx = 0
    }

    private func addressFromBytes(bytes: UnsafeBufferPointer<UInt8>) -> OpenSSLCertificate.IPAddress? {
        switch bytes.count {
        case 4:
            let addr = bytes.baseAddress?.withMemoryRebound(to: in_addr.self, capacity: 1) {
                return $0.pointee
            }
            guard let innerAddr = addr else {
                return nil
            }
            return .ipv4(innerAddr)
        case 16:
            let addr = bytes.baseAddress?.withMemoryRebound(to: in6_addr.self, capacity: 1) {
                return $0.pointee
            }
            guard let innerAddr = addr else {
                return nil
            }
            return .ipv6(innerAddr)
        default:
            return nil
        }
    }

    func next() -> OpenSSLCertificate.AlternativeName? {
        guard nextIdx < stackSize else {
            return nil
        }

        guard let name = CNIOOpenSSL_sk_GENERAL_NAME_value(nameStack, nextIdx) else {
            fatalError("Unexpected null pointer when unwrapping SAN value")
        }

        nextIdx += 1

        switch name.pointee.type {
        case GEN_DNS:
            let namePtr = UnsafeBufferPointer(start: CNIOOpenSSL_ASN1_STRING_get0_data(name.pointee.d.ia5),
                                              count: Int(ASN1_STRING_length(name.pointee.d.ia5)))
            guard let nameString = String(bytes: namePtr, encoding: .ascii) else {
                // This should throw, but we can't throw from next(). Skip this instead.
                return next()
            }
            return .dnsName(nameString)
        case GEN_IPADD:
            let addrPtr = UnsafeBufferPointer(start: CNIOOpenSSL_ASN1_STRING_get0_data(name.pointee.d.ia5),
                                              count: Int(ASN1_STRING_length(name.pointee.d.ia5)))
            guard let addr = addressFromBytes(bytes: addrPtr) else {
                // This should throw, but we can't throw from next(). Skip this instead.
                return next()
            }
            return .ipAddress(addr)
        default:
            // We don't recognise this name type. Skip it.
            return next()
        }
    }

    deinit {
        GENERAL_NAMES_free(nameStack)
    }
}
