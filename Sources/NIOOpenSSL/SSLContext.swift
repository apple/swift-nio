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

import struct Foundation.URL
import struct Foundation.ObjCBool
import class Foundation.FileManager
import NIO
import CNIOOpenSSL

// This is a neat trick. Swift lazily initializes module-globals based on when they're first
// used. This lets us defer OpenSSL intialization as late as possible and only do it if people
// actually create any object that uses OpenSSL.
fileprivate var initialized: Bool = initializeOpenSSL()

// This insane extension is required for Linux. Annoyingly, Linux Foundation as of Swift 4
// declares ObjCBool as a typealias of Bool, meaning it's quite substantially incompatible with
// the Darwin ObjCBool type. In our case we just need boolValue, but sadly we need to shove this
// extension in to get this to work as intended.
// See also: https://github.com/apple/swift-corelibs-foundation/pull/1223
#if os(Linux)
    extension ObjCBool {
        var boolValue: Bool {
            return self
        }
    }
#endif

// This bizarre extension to UnsafeBufferPointer is very useful for handling ALPN identifiers. OpenSSL
// likes to work with them in wire format, so rather than us decoding them we can just encode ours to
// the wire format and then work with them from there.
private extension UnsafeBufferPointer where Element == UInt8 {
    func locateAlpnIdentifier<T>(identifier: UnsafeBufferPointer<T>) -> (index: Int, length: Int)? where T == Element {
        precondition(identifier.count != 0)
        let targetLength = Int(identifier[0])

        var index = 0
        outerLoop: while index < self.count {
            let length = Int(self[index])
            guard index + length + 1 <= self.count else {
                // Invalid length of ALPN identifier, no match.
                return nil
            }

            guard targetLength == length else {
                index += length + 1
                continue outerLoop
            }

            for innerIndex in 1...length {
                guard identifier[innerIndex] == self[index + innerIndex] else {
                    index += length + 1
                    continue outerLoop
                }
            }

            // Found it
            return (index: index + 1, length: length)
        }
        return nil
    }
}

private func verifyCallback(preverifyOk: Int32, ctx: UnsafeMutablePointer<X509_STORE_CTX>?) -> Int32 {
    // This is a no-op verify callback for use with OpenSSL.
    return preverifyOk
}

private func alpnCallback(ssl: UnsafeMutablePointer<SSL>?,
                          out: UnsafeMutablePointer<UnsafePointer<UInt8>?>?,
                          outlen: UnsafeMutablePointer<UInt8>?,
                          in: UnsafePointer<UInt8>?,
                          inlen: UInt32,
                          appData: UnsafeMutableRawPointer?) -> Int32 {
    // Perform some sanity checks. We don't want NULL pointers around here.
    guard let ssl = ssl, let out = out, let outlen = outlen, let `in` = `in` else {
        return SSL_TLSEXT_ERR_ALERT_FATAL
    }

    // We want to take the SSL pointer and extract the parent Swift object.
    let parentCtx = SSL_get_SSL_CTX(ssl)!
    let parentPtr = CNIOOpenSSL_SSL_CTX_get_app_data(parentCtx)!
    let parentSwiftContext: SSLContext = Unmanaged.fromOpaque(parentPtr).takeUnretainedValue()

    let offeredProtocols = UnsafeBufferPointer(start: `in`, count: Int(inlen))
    guard let (index, length) = parentSwiftContext.alpnSelectCallback(offeredProtocols: offeredProtocols) else {
        out.pointee = nil
        outlen.pointee = 0
        return SSL_TLSEXT_ERR_ALERT_FATAL
    }

    out.pointee = `in` + index
    outlen.pointee = UInt8(length)
    return SSL_TLSEXT_ERR_OK
}


public final class SSLContext {
    private let sslContext: UnsafeMutablePointer<SSL_CTX>
    internal let configuration: TLSConfiguration
    
    public init(configuration: TLSConfiguration) throws {
        precondition(initialized)
        guard let ctx = SSL_CTX_new(SSLv23_method()) else { throw NIOOpenSSLError.unableToAllocateOpenSSLObject }

        // TODO(cory): It doesn't seem like this initialization should happen here: where?
        CNIOOpenSSL_SSL_CTX_setAutoECDH(ctx)

        var opensslOptions = Int(SSL_OP_NO_COMPRESSION)

        // Handle TLS versions
        switch configuration.minimumTLSVersion {
        case .tlsv13:
            opensslOptions |= Int(SSL_OP_NO_TLSv1_2)
            fallthrough
        case .tlsv12:
            opensslOptions |= Int(SSL_OP_NO_TLSv1_1)
            fallthrough
        case .tlsv11:
            opensslOptions |= Int(SSL_OP_NO_TLSv1)
            fallthrough
        case .tlsv1:
            opensslOptions |= Int(SSL_OP_NO_SSLv3)
            fallthrough
        case .sslv3:
            opensslOptions |= Int(SSL_OP_NO_SSLv2)
            fallthrough
        case .sslv2:
            break
        }

        switch configuration.maximumTLSVersion {
        case .some(.sslv2):
            opensslOptions |= Int(SSL_OP_NO_SSLv3)
            fallthrough
        case .some(.sslv3):
            opensslOptions |= Int(SSL_OP_NO_TLSv1)
            fallthrough
        case .some(.tlsv1):
            opensslOptions |= Int(SSL_OP_NO_TLSv1_1)
            fallthrough
        case .some(.tlsv11):
            opensslOptions |= Int(SSL_OP_NO_TLSv1_2)
        case .some(.tlsv12), .some(.tlsv13), .none:
            break
        }

        // It's not really very clear here, but this is the actual way to spell SSL_CTX_set_options in Swift code.
        // Sadly, SSL_CTX_set_options is a macro, which means we cannot use it directly, and our modulemap doesn't
        // reveal it in a helpful way, so we write it like this instead.
        SSL_CTX_ctrl(ctx, SSL_CTRL_OPTIONS, opensslOptions, nil)

        // Cipher suites. We just pass this straight to OpenSSL.
        configuration.cipherSuites.withCString {
            precondition(1 == SSL_CTX_set_cipher_list(ctx, $0))
        }

        // If validation is turned on, set the trust roots and turn on cert validation.
        switch configuration.certificateVerification {
        case .fullVerification, .noHostnameVerification:
            SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, verifyCallback)

            switch configuration.trustRoots {
            case .some(.default), .none:
                precondition(1 == SSL_CTX_set_default_verify_paths(ctx))
            case .some(.file(let f)):
                try SSLContext.loadVerifyLocations(f, context: ctx)
            case .some(.certificates(let certs)):
                    try certs.forEach { try SSLContext.addRootCertificate($0, context: ctx) }
            }
        default:
            break
        }

        // If we were given a certificate chain to use, load it and its associated private key.
        var leaf = true
        try configuration.certificateChain.forEach {
            switch $0 {
            case .file(let p):
                SSLContext.useCertificateChainFile(p, context:ctx)
                leaf = false
            case .certificate(let cert):
                if leaf {
                    try SSLContext.setLeafCertificate(cert, context: ctx)
                    leaf = false
                } else {
                    try SSLContext.addAdditionalChainCertificate(cert, context: ctx)
                }
            }
        }

        if let pkey = configuration.privateKey {
            switch pkey {
            case .file(let p):
                SSLContext.usePrivateKeyFile(p, context: ctx)
            case .privateKey(let key):
                try SSLContext.setPrivateKey(key, context: ctx)
            }
        }

        if configuration.applicationProtocols.count > 0 {
            try SSLContext.setAlpnProtocols(configuration.applicationProtocols, context: ctx)
            SSLContext.setAlpnCallback(context: ctx)
        }

        self.sslContext = ctx
        self.configuration = configuration

        // Always make it possible to get from an SSL_CTX structure back to this.
        let ptrToSelf = Unmanaged.passUnretained(self).toOpaque()
        CNIOOpenSSL_SSL_CTX_set_app_data(ctx, ptrToSelf)
    }

    internal func createConnection() -> SSLConnection? {
        guard let ssl = SSL_new(sslContext) else {
            return nil
        }
        return SSLConnection(ssl, parentContext:self)
    }

    fileprivate func alpnSelectCallback(offeredProtocols: UnsafeBufferPointer<UInt8>) ->  (index: Int, length: Int)? {
        for possibility in configuration.applicationProtocols {
            let match = possibility.withUnsafeBufferPointer {
                offeredProtocols.locateAlpnIdentifier(identifier: $0)
            }
            if match != nil { return match }
        }

        return nil
    }

    deinit {
        SSL_CTX_free(sslContext)
    }
}


extension SSLContext {
    private static func useCertificateChainFile(_ path: String, context: UnsafeMutablePointer<SSL_CTX>) {
        // TODO(cory): This shouldn't be an assert but should instead be actual error handling.
        // assert(path.isFileURL)
        let result = path.withCString { (pointer) -> Int32 in
            return SSL_CTX_use_certificate_chain_file(context, pointer)
        }
        
        // TODO(cory): again, some error handling would be good.
        precondition(result == 1)
    }

    private static func setLeafCertificate(_ cert: OpenSSLCertificate, context: UnsafeMutablePointer<SSL_CTX>) throws {
        let rc = SSL_CTX_use_certificate(context, cert.ref)
        guard rc == 1 else {
            throw NIOOpenSSLError.failedToLoadCertificate
        }
    }
    
    private static func addAdditionalChainCertificate(_ cert: OpenSSLCertificate, context: UnsafeMutablePointer<SSL_CTX>) throws {
        // This dup is necessary because the SSL_CTX_ctrl doesn't copy the X509 object itself.
        guard 1 == SSL_CTX_ctrl(context, SSL_CTRL_EXTRA_CHAIN_CERT, 0, X509_dup(cert.ref)) else {
            throw NIOOpenSSLError.failedToLoadCertificate
        }
    }
    
    private static func setPrivateKey(_ key: OpenSSLPrivateKey, context: UnsafeMutablePointer<SSL_CTX>) throws {
        guard 1 == SSL_CTX_use_PrivateKey(context, key.ref) else {
            throw NIOOpenSSLError.failedToLoadPrivateKey
        }
    }
    
    private static func addRootCertificate(_ cert: OpenSSLCertificate, context: UnsafeMutablePointer<SSL_CTX>) throws {
        let store = SSL_CTX_get_cert_store(context)!
        if 0 == X509_STORE_add_cert(store, cert.ref) {
            throw NIOOpenSSLError.failedToLoadCertificate
        }
    }
    
    private static func usePrivateKeyFile(_ path: String, context: UnsafeMutablePointer<SSL_CTX>) {
        // TODO(cory): This shouldn't be an assert but should instead be actual error handling.
        // assert(atPath.isFileURL)
        let path = URL(string: path)!
        let fileType: Int32
        
        switch path.pathExtension.lowercased() {
        case "pem":
            fileType = SSL_FILETYPE_PEM
        case "der", "key":
            fileType = SSL_FILETYPE_ASN1
        default:
            // TODO(cory): Again, error handling here would be good.
            fatalError("Unknown private key file type.")
        }
        
        let result = path.withUnsafeFileSystemRepresentation { (pointer) -> Int32 in
            return SSL_CTX_use_PrivateKey_file(context, pointer, fileType)
        }
        
        // TODO(cory): again, some error handling would be good.
        precondition(result == 1)
    }
    
    private static func loadVerifyLocations(_ path: String, context: UnsafeMutablePointer<SSL_CTX>) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager().fileExists(atPath: path, isDirectory: &isDirectory)
        guard exists else {
            throw NIOOpenSSLError.noSuchFilesystemObject
        }
        
        let result = path.withCString { (pointer) -> Int32 in
            let file = !(isDirectory.boolValue) ? pointer : nil
            let directory = isDirectory.boolValue ? pointer: nil
            return SSL_CTX_load_verify_locations(context, file, directory)
        }
        
        if result == 0 {
            let errorStack = OpenSSLError.buildErrorStack()
            throw OpenSSLError.unknownError(errorStack)
        }
    }

    private static func setAlpnProtocols(_ protocols: [[UInt8]], context: UnsafeMutablePointer<SSL_CTX>) throws {
        // This copy should be done infrequently, so we don't worry too much about it.
        let protoBuf = protocols.reduce([UInt8](), +)
        let rc = protoBuf.withUnsafeBufferPointer {
            CNIOOpenSSL_SSL_CTX_set_alpn_protos(context, $0.baseAddress!, UInt32($0.count))
        }

        // Annoyingly this function reverses the error convention: 0 is success, non-zero is failure.
        if rc != 0 {
            let errorStack = OpenSSLError.buildErrorStack()
            throw OpenSSLError.failedToSetALPN(errorStack)
        }
    }

    private static func setAlpnCallback(context: UnsafeMutablePointer<SSL_CTX>) {
        CNIOOpenSSL_SSL_CTX_set_alpn_select_cb(context, alpnCallback, nil)
    }
}
