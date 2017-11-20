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
import CNIOOpenSSL
@testable import NIO
@testable import NIOOpenSSL
import NIOTLS

class ErrorCatcher<T: Error>: ChannelInboundHandler {
    public typealias InboundIn = Any
    public var errors: [T]

    public init() {
        errors = []
    }

    public func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        errors.append(error as! T)
    }
}

class TLSConfigurationTest: XCTestCase {
    static var cert1: OpenSSLCertificate!
    static var key1: OpenSSLPrivateKey!

    static var cert2: OpenSSLCertificate!
    static var key2: OpenSSLPrivateKey!

    override class func setUp() {
        super.setUp()
        var (cert, key) = generateSelfSignedCert()
        TLSConfigurationTest.cert1 = cert
        TLSConfigurationTest.key1 = key

        (cert, key) = generateSelfSignedCert()
        TLSConfigurationTest.cert2 = cert
        TLSConfigurationTest.key2 = key
    }

    func assertHandshakeError(withClientConfig clientConfig: TLSConfiguration,
                              andServerConfig serverConfig: TLSConfiguration,
                              errorTextContains message: String) throws {
        return try assertHandshakeError(withClientConfig: clientConfig,
                                        andServerConfig: serverConfig,
                                        errorTextContainsAnyOf: [message])
    }

    func assertHandshakeError(withClientConfig clientConfig: TLSConfiguration,
                              andServerConfig serverConfig: TLSConfiguration,
                              errorTextContainsAnyOf messages: [String]) throws {
        let clientContext = try SSLContext(configuration: clientConfig)
        let serverContext = try SSLContext(configuration: serverConfig)

        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
        }

        let eventHandler = ErrorCatcher<NIOOpenSSLError>()
        let serverChannel = try serverTLSChannel(withContext: serverContext, andHandlers: [], onGroup: group)
        let clientChannel = try clientTLSChannel(withContext: clientContext, preHandlers:[], postHandlers: [eventHandler], onGroup: group, connectingTo: serverChannel.localAddress!)

        // We expect the channel to be closed fairly swiftly as the handshake should fail.
        clientChannel.closeFuture.whenComplete { _ in
            XCTAssertEqual(eventHandler.errors.count, 1)

            switch eventHandler.errors[0] {
            case .handshakeFailed(.sslError(let errs)):
                XCTAssertEqual(errs.count, 1)
                let correctError: Bool = messages.map { errs[0].description.contains($0) }.reduce(false) { $0 || $1 }
                XCTAssert(correctError, errs[0].description)
            default:
                XCTFail("Unexpected error: \(eventHandler.errors[0])")
            }
        }
        try clientChannel.closeFuture.wait()
    }

    func testNonOverlappingTLSVersions() throws {
        let clientConfig = TLSConfiguration.forClient(minimumTLSVersion: .tlsv11, trustRoots: .certificates([TLSConfigurationTest.cert1]))
        let serverConfig = TLSConfiguration.forServer(certificateChain: [.certificate(TLSConfigurationTest.cert1)],
                                                      privateKey: .privateKey(TLSConfigurationTest.key1),
                                                      maximumTLSVersion: .tlsv1)

        try assertHandshakeError(withClientConfig: clientConfig,
                                 andServerConfig: serverConfig,
                                 errorTextContainsAnyOf: ["unsupported protocol", "wrong ssl version"])
    }

    func testNonOverlappingCipherSuites() throws {
        let clientConfig = TLSConfiguration.forClient(cipherSuites: "AES128", trustRoots: .certificates([TLSConfigurationTest.cert1]))
        let serverConfig = TLSConfiguration.forServer(certificateChain: [.certificate(TLSConfigurationTest.cert1)],
                                                      privateKey: .privateKey(TLSConfigurationTest.key1),
                                                      cipherSuites: "AES256")

        try assertHandshakeError(withClientConfig: clientConfig, andServerConfig: serverConfig, errorTextContains: "handshake failure")
    }

    func testCannotVerifySelfSigned() throws {
        let clientConfig = TLSConfiguration.forClient()
        let serverConfig = TLSConfiguration.forServer(certificateChain: [.certificate(TLSConfigurationTest.cert1)],
                                                      privateKey: .privateKey(TLSConfigurationTest.key1))

        try assertHandshakeError(withClientConfig: clientConfig, andServerConfig: serverConfig, errorTextContains: "certificate verify failed")
    }

    func testServerCannotValidateClient() throws {
        let clientConfig = TLSConfiguration.forClient(trustRoots: .certificates([TLSConfigurationTest.cert1]),
                                                      certificateChain: [.certificate(TLSConfigurationTest.cert2)],
                                                      privateKey: .privateKey(TLSConfigurationTest.key2))
        let serverConfig = TLSConfiguration.forServer(certificateChain: [.certificate(TLSConfigurationTest.cert1)],
                                                      privateKey: .privateKey(TLSConfigurationTest.key1),
                                                      certificateVerification: .noHostnameVerification)

        try assertHandshakeError(withClientConfig: clientConfig, andServerConfig: serverConfig, errorTextContains: "alert unknown ca")
    }

    func testMutualValidation() throws {
        let clientConfig = TLSConfiguration.forClient(trustRoots: .certificates([TLSConfigurationTest.cert1]),
                                                      certificateChain: [.certificate(TLSConfigurationTest.cert2)],
                                                      privateKey: .privateKey(TLSConfigurationTest.key2))
        let serverConfig = TLSConfiguration.forServer(certificateChain: [.certificate(TLSConfigurationTest.cert1)],
                                                      privateKey: .privateKey(TLSConfigurationTest.key1),
                                                      certificateVerification: .noHostnameVerification,
                                                      trustRoots: .certificates([TLSConfigurationTest.cert2]))

        let clientContext = try SSLContext(configuration: clientConfig)
        let serverContext = try SSLContext(configuration: serverConfig)

        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
        }

        let eventHandler = EventRecorderHandler<TLSUserEvent>()
        let serverChannel = try serverTLSChannel(withContext: serverContext, andHandlers: [], onGroup: group)
        let clientChannel = try clientTLSChannel(withContext: clientContext, preHandlers: [], postHandlers: [eventHandler], onGroup: group, connectingTo: serverChannel.localAddress!, serverHostname: "localhost")

        // Wait for a successful flush: that indicates the channel is up.
        var buf = clientChannel.allocator.buffer(capacity: 5)
        buf.write(string: "hello")

        // Check that we got a handshakeComplete message indicating mutual validation.
        let flushFuture = clientChannel.writeAndFlush(data: NIOAny(buf))
        flushFuture.whenComplete { _ in
            let handshakeEvents = eventHandler.events.filter {
                switch $0 {
                case .UserEvent(.handshakeCompleted):
                    return true
                default:
                    return false
                }
            }

            XCTAssertEqual(handshakeEvents.count, 1)
        }
        try flushFuture.wait()
    }
}
