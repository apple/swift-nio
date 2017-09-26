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

public final class SSLContext {
    private let sslContext: UnsafeMutablePointer<SSL_CTX>
    
    public init? () {
        precondition(initialized)
        guard let ctx = SSL_CTX_new(SSLv23_method()) else { return nil }
        
        // TODO(cory): It doesn't seem like this initialization should happen here: where?
        // TODO(cory): Probably there should be some kind of configuration struct that can be
        // used to override our settings.
        SSL_CTX_setAutoECDH(ctx)
        assert(1 == SSL_CTX_set_default_verify_paths(ctx))

        // TODO(cory): Oh god oh god what about OpenSSL 1.1 and the great opaquifying?
        // This can only really be fixed by requiring that the modulemap for OpenSSL expose
        // this flag in an appropriate function.
        ctx.pointee.options |= UInt(
            SSL_OP_NO_SSLv2 |
            SSL_OP_NO_SSLv3 |
            SSL_OP_NO_COMPRESSION
        )
        
        sslContext = ctx
    }
    
    public func useCertificateChainFile(atPath: URL) {
        // TODO(cory): This shouldn't be an assert but should instead be actual error handling.
        // assert(atPath.isFileURL)
        let result = atPath.withUnsafeFileSystemRepresentation { (pointer) -> Int32 in
            return SSL_CTX_use_certificate_chain_file(sslContext, pointer)
        }
        
        // TODO(cory): again, some error handling would be good.
        assert(result == 1)
    }
    
    // TODO(cory): There should really be a wrapper object here with some useful methods, not least because
    // otherwise it's very easy to leak these cert objects, but for now this will do.
    public func setLeafCertificate(_ cert: UnsafeMutablePointer<X509>) throws {
        let rc = SSL_CTX_use_certificate(sslContext, cert)
        guard rc == 1 else {
            throw NIOOpenSSLError.failedToLoadCertificate
        }
    }
    
    public func addAdditionalChainCertificate(_ cert: UnsafeMutablePointer<X509>) throws {
        // TODO(cory): When we add a wrapper here, we probably need to do an X509_dup here
        // to avoid leaking the additional chain cert: as far as I can tell SSL_CTX_ctrl doesn't
        // retain the extra cert objects.
        guard 1 == SSL_CTX_ctrl(sslContext, SSL_CTRL_EXTRA_CHAIN_CERT, 0, cert) else {
            throw NIOOpenSSLError.failedToLoadCertificate
        }
    }
    
    public func setPrivateKey(_ key: UnsafeMutablePointer<EVP_PKEY>) throws {
        guard 1 == SSL_CTX_use_PrivateKey(sslContext, key) else {
            throw NIOOpenSSLError.failedToLoadPrivateKey
        }
    }
    
    public func addRootCertificate(_ cert: UnsafeMutablePointer<X509>) throws {
        let store = SSL_CTX_get_cert_store(sslContext)!
        guard 0 != X509_STORE_add_cert(store, cert) else {
            throw NIOOpenSSLError.failedToLoadCertificate
        }
    }
    
    public func usePrivateKeyFile(atPath: URL) {
        // TODO(cory): This shouldn't be an assert but should instead be actual error handling.
        // assert(atPath.isFileURL)
        let fileType: Int32
        
        switch atPath.pathExtension.lowercased() {
        case "pem":
            fileType = SSL_FILETYPE_PEM
        case "der", "key":
            fileType = SSL_FILETYPE_ASN1
        default:
            // TODO(cory): Again, error handling here would be good.
            fatalError("Unknown private key file type.")
        }
        
        let result = atPath.withUnsafeFileSystemRepresentation { (pointer) -> Int32 in
            return SSL_CTX_use_PrivateKey_file(sslContext, pointer, fileType)
        }
        
        // TODO(cory): again, some error handling would be good.
        assert(result == 1)
    }
    
    public func loadVerifyLocations(atPath: String) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager().fileExists(atPath: atPath, isDirectory: &isDirectory)
        guard exists else {
            throw NIOOpenSSLError.noSuchFilesystemObject
        }
        
        let result = atPath.withCString { (pointer) -> Int32 in
            let file = !(isDirectory.boolValue) ? pointer : nil
            let directory = isDirectory.boolValue ? pointer: nil
            return SSL_CTX_load_verify_locations(sslContext, file, directory)
        }
        
        if result == 0 {
            let errorStack = OpenSSLError.buildErrorStack()
            throw OpenSSLError.unknownError(errorStack)
        }
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
