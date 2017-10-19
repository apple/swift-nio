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

public enum TLSVersion {
    case sslv2
    case sslv3
    case tlsv1
    case tlsv11
    case tlsv12
    case tlsv13
}

public enum OpenSSLCertificateSource {
    case file(String)
    case certificate(OpenSSLCertificate)
}

public enum OpenSSLPrivateKeySource {
    case file(String)
    case privateKey(OpenSSLPrivateKey)
}

public enum OpenSSLTrustRoots {
    case file(String)
    case certificates([OpenSSLCertificate])
    case `default`
}

public enum OpenSSLSerializationFormats {
    case pem
    case der
}

/// A secure default configuration of cipher suites.
///
/// The goal of this cipher suite string is:
/// - Prefer TLS 1.3 cipher suites.
/// - Prefer cipher suites that offer Perfect Forward Secrecy (DHE/ECDHE)
/// - Prefer ECDH(E) to DH(E) for performance.
/// - Prefer any AEAD cipher suite over non-AEAD suites for better performance and security
/// - Prefer AES-GCM over ChaCha20 because hardware-accelerated AES is common
/// - Disable NULL authentication and encryption and any appearance of MD5
public let defaultCipherSuites = [
    "TLS13-AES-256-GCM-SHA384",
    "TLS13-CHACHA20-POLY1305-SHA256",
    "TLS13-AES-128-GCM-SHA256",
    "ECDH+AESGCM",
    "ECDH+CHACHA20",
    "DH+AESGCM",
    "DH+CHACHA20",
    "ECDH+AES256",
    "DH+AES256",
    "ECDH+AES128",
    "DH+AES",
    "RSA+AESGCM",
    "RSA+AES",
    "!aNULL",
    "!eNULL",
    "!MD5",
    ].joined(separator: ":")

/// Manages configuration of OpenSSL for SwiftNIO programs.
///
/// OpenSSL has a number of configuration options that are worth setting. This structure allows
/// setting those options in a more expressive manner than OpenSSL itself allows.
public struct TLSConfiguration {
    /// A default TLS configuration for client use.
    public static let clientDefault = TLSConfiguration.forClient()

    /// The minimum TLS version to allow in negotiation. Defaults to tlsv1.
    public let minimumTLSVersion: TLSVersion

    /// The maximum TLS version to allow in negotiation. If nil, there is no upper limit. Defaults to nil.
    public let maximumTLSVersion: TLSVersion?

    /// The cipher suites supported by this handler. This uses the OpenSSL cipher string format.
    public let cipherSuites: String

    /// Whether to verify remote certificates.
    public let certificateVerification: Bool

    /// The trust roots to use to validate certificates. This only needs to be provided if you intend to validate
    /// certificates.
    public let trustRoots: OpenSSLTrustRoots?

    /// The certificates to offer during negotiation. If not present, no certificates will be offered.
    public let certificateChain: [OpenSSLCertificateSource]

    /// The private key associated with the leaf certificate.
    public let privateKey: OpenSSLPrivateKeySource?

    private init(cipherSuites: String,
                minimumTLSVersion: TLSVersion,
                maximumTLSVersion: TLSVersion?,
                certificateVerification: Bool,
                trustRoots: OpenSSLTrustRoots,
                certificateChain: [OpenSSLCertificateSource],
                privateKey: OpenSSLPrivateKeySource?) {
        self.cipherSuites = cipherSuites
        self.minimumTLSVersion = minimumTLSVersion
        self.maximumTLSVersion = maximumTLSVersion
        self.certificateVerification = certificateVerification
        self.trustRoots = trustRoots
        self.certificateChain = certificateChain
        self.privateKey = privateKey
    }

    /// Create a TLS configuration for use with server-side contexts.
    ///
    /// This provides sensible defaults while requiring that you provide any data that is necessary
    /// for server-side function. For client use, try `forClient` instead.
    public static func forServer(certificateChain: [OpenSSLCertificateSource],
                                 privateKey: OpenSSLPrivateKeySource,
                                 cipherSuites: String = defaultCipherSuites,
                                 minimumTLSVersion: TLSVersion = .tlsv1,
                                 maximumTLSVersion: TLSVersion? = nil,
                                 certificateVerification: Bool = false,
                                 trustRoots: OpenSSLTrustRoots = .default) -> TLSConfiguration {
        return TLSConfiguration(cipherSuites: cipherSuites,
                                minimumTLSVersion: minimumTLSVersion,
                                maximumTLSVersion: maximumTLSVersion,
                                certificateVerification: certificateVerification,
                                trustRoots: trustRoots,
                                certificateChain: certificateChain,
                                privateKey: privateKey)
    }


    /// Creates a TLS configuration for use with client-side contexts.
    ///
    /// This provides sensible defaults, and can be used without customisation. For server-side
    /// contexts, you should use `forServer` instead.
    public static func forClient(cipherSuites: String = defaultCipherSuites,
                                 minimumTLSVersion: TLSVersion = .tlsv1,
                                 maximumTLSVersion: TLSVersion? = nil,
                                 certificateVerification: Bool = true,
                                 trustRoots: OpenSSLTrustRoots = .default,
                                 certificateChain: [OpenSSLCertificateSource] = [],
                                 privateKey: OpenSSLPrivateKeySource? = nil) -> TLSConfiguration {
        return TLSConfiguration(cipherSuites: cipherSuites,
                                minimumTLSVersion: minimumTLSVersion,
                                maximumTLSVersion: maximumTLSVersion,
                                certificateVerification: certificateVerification,
                                trustRoots: trustRoots,
                                certificateChain: certificateChain,
                                privateKey: privateKey)
    }
}
