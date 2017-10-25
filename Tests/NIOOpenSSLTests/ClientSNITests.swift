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
import NIOTLS
import NIOOpenSSL


class ClientSNITests: XCTestCase {
    static var cert: OpenSSLCertificate!
    static var key: OpenSSLPrivateKey!

    override class func setUp() {
        super.setUp()
        let (cert, key) = generateSelfSignedCert()
        OpenSSLIntegrationTest.cert = cert
        OpenSSLIntegrationTest.key = key
    }

    private func configuredSSLContext() throws -> NIOOpenSSL.SSLContext {
        let config = TLSConfiguration.forServer(certificateChain: [.certificate(OpenSSLIntegrationTest.cert)],
                                                privateKey: .privateKey(OpenSSLIntegrationTest.key),
                                                trustRoots: .certificates([OpenSSLIntegrationTest.cert]))
        let ctx = try SSLContext(configuration: config)
        return ctx
    }

    private func assertSniResult(sniField: String?, expectedResult: SniResult) throws {
        let ctx = try configuredSSLContext()

        let group = try MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
        }

        let sniPromise: Promise<SniResult> = group.next().newPromise()
        let sniHandler = SniHandler {
            sniPromise.succeed(result: $0)
            return group.next().newSucceedFuture(result: ())
        }
        let serverChannel = try serverTLSChannel(withContext: ctx, preHandlers: [sniHandler], postHandlers: [], onGroup: group)
        defer {
            _ = try! serverChannel.close().wait()
        }

        let clientChannel = try clientTLSChannel(withContext: ctx,
                                                 preHandlers: [],
                                                 postHandlers: [],
                                                 onGroup: group,
                                                 connectingTo: serverChannel.localAddress!,
                                                 serverHostname: sniField)
        defer {
            _ = try! clientChannel.close().wait()
        }

        let sniResult = try sniPromise.futureResult.wait()
        XCTAssertEqual(sniResult, expectedResult)
    }

    func testSNIIsTransmitted() throws {
        try assertSniResult(sniField: "httpbin.org", expectedResult: .hostname("httpbin.org"))
    }

    func testNoSNILeadsToNoExtension() throws {
        try assertSniResult(sniField: nil, expectedResult: .fallback)
    }

    func testSNIIsRejectedForIPv4Addresses() throws {
        let ctx = try configuredSSLContext()

        do {
            _ = try OpenSSLClientHandler(context: ctx, serverHostname: "192.168.0.1")
            XCTFail("Created client handler with invalid SNI name")
        } catch OpenSSLError.invalidSNIName {
            // All fine.
        }
    }

    func testSNIIsRejectedForIPv6Addresses() throws {
        let ctx = try configuredSSLContext()

        do {
            _ = try OpenSSLClientHandler(context: ctx, serverHostname: "fe80::200:f8ff:fe21:67cf")
            XCTFail("Created client handler with invalid SNI name")
        } catch OpenSSLError.invalidSNIName {
            // All fine.
        }
    }
}
