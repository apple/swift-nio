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

import CNIOOpenSSL
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    import Darwin
#elseif os(Linux)
    import Glibc
#endif

public struct OpenSSLInternalError: Equatable, CustomStringConvertible {
    let errorCode: u_long

    var errorMessage: String? {
        if let cErrorMessage = ERR_error_string(errorCode, nil) {
            return String.init(cString: cErrorMessage)
        }
        return nil
    }

    public var description: String {
        return"Error: \(errorCode) \(errorMessage ?? "")"
    }

    init(errorCode: u_long) {
        self.errorCode = errorCode
    }

    public static func ==(lhs: OpenSSLInternalError, rhs: OpenSSLInternalError) -> Bool {
        return lhs.errorCode == rhs.errorCode
    }

}

public typealias OpenSSLErrorStack = [OpenSSLInternalError]


public enum NIOOpenSSLError: Error {
    case writeDuringTLSShutdown
    case unableToAllocateOpenSSLObject
    case noSuchFilesystemObject
    case failedToLoadCertificate
    case failedToLoadPrivateKey
    case handshakeFailed(OpenSSLError)
    case shutdownFailed(OpenSSLError)
    case cannotMatchULabel
    case noCertificateToValidate
    case unableToValidateCertificate
    case cannotFindPeerIP
}

extension NIOOpenSSLError: Equatable {
    public static func ==(lhs: NIOOpenSSLError, rhs: NIOOpenSSLError) -> Bool {
        switch (lhs, rhs) {
        case (.writeDuringTLSShutdown, .writeDuringTLSShutdown),
             (.unableToAllocateOpenSSLObject, .unableToAllocateOpenSSLObject),
             (.noSuchFilesystemObject, .noSuchFilesystemObject),
             (.failedToLoadCertificate, .failedToLoadCertificate),
             (.failedToLoadPrivateKey, .failedToLoadPrivateKey),
             (.cannotMatchULabel, .cannotMatchULabel),
             (.noCertificateToValidate, .noCertificateToValidate),
             (.unableToValidateCertificate, .unableToValidateCertificate):
            return true
        case (.handshakeFailed(let err1), .handshakeFailed(let err2)),
             (.shutdownFailed(let err1), .shutdownFailed(let err2)):
            return err1 == err2
        default:
            return false
        }
    }
}

public enum OpenSSLError: Error {
    case noError
    case zeroReturn
    case wantRead
    case wantWrite
    case wantConnect
    case wantAccept
    case wantX509Lookup
    case syscallError
    case sslError(OpenSSLErrorStack)
    case unknownError(OpenSSLErrorStack)
    case uncleanShutdown
    case invalidSNIName(OpenSSLErrorStack)
    case failedToSetALPN(OpenSSLErrorStack)
}

extension OpenSSLError: Equatable {}

public func ==(lhs: OpenSSLError, rhs: OpenSSLError) -> Bool {
    switch (lhs, rhs) {
    case (.noError, .noError),
         (.zeroReturn, .zeroReturn),
         (.wantRead, .wantRead),
         (.wantWrite, .wantWrite),
         (.wantConnect, .wantConnect),
         (.wantAccept, .wantAccept),
         (.wantX509Lookup, .wantX509Lookup),
         (.syscallError, .syscallError),
         (.uncleanShutdown, .uncleanShutdown):
        return true
    case (.sslError(let e1), .sslError(let e2)),
         (.unknownError(let e1), .unknownError(let e2)):
        return e1 == e2
    default:
        return false
    }
}

internal extension OpenSSLError {
    static func fromSSLGetErrorResult(_ result: Int32) -> OpenSSLError? {
        switch result {
        case SSL_ERROR_NONE:
            return .noError
        case SSL_ERROR_ZERO_RETURN:
            return .zeroReturn
        case SSL_ERROR_WANT_READ:
            return .wantRead
        case SSL_ERROR_WANT_WRITE:
            return .wantWrite
        case SSL_ERROR_WANT_CONNECT:
            return .wantConnect
        case SSL_ERROR_WANT_ACCEPT:
            return .wantAccept
        case SSL_ERROR_WANT_X509_LOOKUP:
            return .wantX509Lookup
        case SSL_ERROR_SYSCALL:
            return .syscallError
        case SSL_ERROR_SSL:
            return .sslError(buildErrorStack())
        default:
            return .unknownError(buildErrorStack())
        }
    }
    
    static func buildErrorStack() -> OpenSSLErrorStack {
        var errorStack = OpenSSLErrorStack()
        
        while true {
            let errorCode = ERR_get_error()
            if errorCode == 0 { break }
            errorStack.append(OpenSSLInternalError(errorCode: errorCode))
        }
        
        return errorStack
    }
}
