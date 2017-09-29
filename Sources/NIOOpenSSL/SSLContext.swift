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
import OpenSSL

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

private func verifyCallback(preverifyOk: Int32, ctx: UnsafeMutablePointer<X509_STORE_CTX>?) -> Int32 {
    // This is a no-op verify callback for use with OpenSSL.
    return preverifyOk
}


public final class SSLContext {
    private let sslContext: UnsafeMutablePointer<SSL_CTX>
    
    public init(configuration: TLSConfiguration) throws {
        precondition(initialized)
        guard let ctx = SSL_CTX_new(SSLv23_method()) else { throw NIOOpenSSLError.unableToAllocateOpenSSLObject }

        // TODO(cory): It doesn't seem like this initialization should happen here: where?
        SSL_CTX_setAutoECDH(ctx)

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
        if configuration.certificateVerification {
            SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, verifyCallback)

            switch configuration.trustRoots {
            case .some(.default), .none:
                precondition(1 == SSL_CTX_set_default_verify_paths(ctx))
            case .some(.file(let f)):
                try SSLContext.loadVerifyLocations(f, context: ctx)
            case .some(.certificates(let certs)):
                    try certs.forEach { try SSLContext.addRootCertificate($0, context: ctx) }
            }
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

        sslContext = ctx
    }

    internal func createConnection() -> SSLConnection? {
        guard let ssl = SSL_new(sslContext) else {
            return nil
        }
        return SSLConnection(ssl, parentContext:self)
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
        guard 0 != X509_STORE_add_cert(store, cert.ref) else {
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

}
