//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOEmbedded
import NIOHTTP1
import Testing

@Suite struct HTTPServerPipelineSetupTests {
    @Test(arguments: Options.all)
    func configureHTTPServerPipeline(options: Options) throws {
        try expectPipeline(NIOHTTPServerPipelineConfiguration.self, configuredWith: options) { channel, configuration in
            try channel.pipeline.configureHTTPServerPipeline(configuration: configuration).wait()
        }
    }

    @Test(arguments: Options.all)
    func syncConfigureHTTPServerPipeline(options: Options) throws {
        try expectPipeline(
            NIOHTTPServerPipelineSynchronousConfiguration.self,
            configuredWith: options
        ) { channel, configuration in
            try channel.pipeline.syncOperations.configureHTTPServerPipeline(configuration: configuration)
        }
    }

    @available(*, deprecated, message: "Tests deprecated method")
    @Test(arguments: Options.all)
    func configureHTTPServerPipelineWithDeprecatedHelper(options: Options) throws {
        try expectPipeline(NIOHTTPServerPipelineConfiguration.self, configuredWith: options) { channel, configuration in
            try channel.pipeline.configureHTTPServerPipeline(
                withPipeliningAssistance: configuration.pipeliningAssistance,
                withServerUpgrade: configuration.serverUpgrade.map { ($0.upgraders, $0.completionHandler) },
                withErrorHandling: configuration.errorHandling,
                withOutboundHeaderValidation: configuration.outboundHeaderValidation,
                withEncoderConfiguration: configuration.encoderConfiguration,
                withDecoderLimitConfiguration: configuration.decoderLimitConfiguration
            ).wait()
        }
    }

    @available(*, deprecated, message: "Tests deprecated method")
    @Test(arguments: Options.all)
    func syncConfigureHTTPServerPipelineWithDeprecatedHelper(options: Options) throws {
        try expectPipeline(NIOHTTPServerPipelineConfiguration.self, configuredWith: options) { channel, configuration in
            try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                withPipeliningAssistance: configuration.pipeliningAssistance,
                withServerUpgrade: configuration.serverUpgrade.map { ($0.upgraders, $0.completionHandler) },
                withErrorHandling: configuration.errorHandling,
                withOutboundHeaderValidation: configuration.outboundHeaderValidation,
                withEncoderConfiguration: configuration.encoderConfiguration,
                withDecoderLimitConfiguration: configuration.decoderLimitConfiguration
            )
        }
    }
}

extension HTTPServerPipelineSetupTests {
    /// One combination of enabling or disabling each pipeline configuration setting.
    struct Options: Sendable, CustomTestStringConvertible {
        var pipeliningAssistance: Bool
        var errorHandling: Bool
        var outboundHeaderValidation: Bool
        var serverUpgrade: Bool
        var automaticallySetFramingHeaders: Bool
        var customDecoderLimits: Bool

        /// Every combination of the options.
        static let all: [Self] = (0..<64).map { bits in
            Self(
                pipeliningAssistance: bits & 1 != 0,
                errorHandling: bits & 2 != 0,
                outboundHeaderValidation: bits & 4 != 0,
                serverUpgrade: bits & 8 != 0,
                automaticallySetFramingHeaders: bits & 16 != 0,
                customDecoderLimits: bits & 32 != 0
            )
        }

        var testDescription: String {
            let enabled = [
                ("pipeliningAssistance", self.pipeliningAssistance),
                ("errorHandling", self.errorHandling),
                ("outboundHeaderValidation", self.outboundHeaderValidation),
                ("serverUpgrade", self.serverUpgrade),
                ("automaticallySetFramingHeaders", self.automaticallySetFramingHeaders),
                ("customDecoderLimits", self.customDecoderLimits),
            ].filter { $0.1 }.map { $0.0 }
            return enabled.isEmpty ? "none" : enabled.joined(separator: ", ")
        }
    }
}

/// Sets up a pipeline by applying `options` to a new `Configuration` and passing it to `configure`. Then checks that
/// the pipeline respects all the configurations in `options`.
private func expectPipeline<Configuration: PipelineConfiguration>(
    _ configurationType: Configuration.Type,
    configuredWith options: HTTPServerPipelineSetupTests.Options,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ configure: (EmbeddedChannel, Configuration) throws -> Void
) throws {
    var configuration = Configuration()
    configuration.apply(options)

    func makeChannel() throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()
        try configure(channel, configuration)
        return channel
    }

    try expectHandlers(in: makeChannel(), for: configuration, sourceLocation: sourceLocation)
    try expectUpgrade(of: makeChannel(), serverUpgrade: options.serverUpgrade, sourceLocation: sourceLocation)
    try expectEncoder(of: makeChannel(), using: configuration.encoderConfiguration, sourceLocation: sourceLocation)
    try expectDecoder(
        of: makeChannel(),
        using: configuration.decoderLimitConfiguration,
        errorHandling: configuration.errorHandling,
        sourceLocation: sourceLocation
    )
}

/// Checks that `channel`'s pipeline has the handlers that `configuration` enables.
private func expectHandlers(
    in channel: EmbeddedChannel,
    for configuration: some PipelineConfiguration,
    sourceLocation: SourceLocation
) throws {
    let sync = channel.pipeline.syncOperations
    #expect(
        sync.hasHandler(HTTPServerPipelineHandler.self) == configuration.pipeliningAssistance,
        sourceLocation: sourceLocation
    )
    #expect(
        sync.hasHandler(HTTPServerProtocolErrorHandler.self) == configuration.errorHandling,
        sourceLocation: sourceLocation
    )
    #expect(
        sync.hasHandler(NIOHTTPResponseHeadersValidator.self) == configuration.outboundHeaderValidation,
        sourceLocation: sourceLocation
    )
    _ = try channel.finish()
}

/// Checks that `TestUpgrader` answers an upgrade request on `channel` when `serverUpgrade` is set.
private func expectUpgrade(of channel: EmbeddedChannel, serverUpgrade: Bool, sourceLocation: SourceLocation) throws {
    let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: test\r\nConnection: upgrade\r\n\r\n"
    try channel.writeInbound(ByteBuffer(string: request))
    channel.embeddedEventLoop.run()
    let upgradeResponse = try channel.readOutbound(as: ByteBuffer.self)
    if serverUpgrade {
        let response = try #require(upgradeResponse, sourceLocation: sourceLocation)
        let header = "\(TestUpgrader.testResponseHeader.name): \(TestUpgrader.testResponseHeader.value)"
        #expect(String(buffer: response).contains(header), sourceLocation: sourceLocation)
    } else {
        #expect(upgradeResponse == nil, sourceLocation: sourceLocation)
    }
    _ = try channel.finish()
}

/// Checks whether `encoderConfiguration` is applied.
private func expectEncoder(
    of channel: EmbeddedChannel,
    using encoderConfiguration: HTTPResponseEncoder.Configuration,
    sourceLocation: SourceLocation
) throws {
    try channel.writeInbound(ByteBuffer(string: "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"))
    try channel.writeOutbound(HTTPServerResponsePart.head(.init(version: .http1_1, status: .ok)))
    let head = try #require(try channel.readOutbound(as: ByteBuffer.self), sourceLocation: sourceLocation)
    #expect(
        String(buffer: head).lowercased().contains("transfer-encoding: chunked")
            == encoderConfiguration.automaticallySetFramingHeaders,
        sourceLocation: sourceLocation
    )
    _ = try? channel.finish()
}

/// Checks whether `decoderLimitConfiguration` is applied.
private func expectDecoder(
    of channel: EmbeddedChannel,
    using decoderLimitConfiguration: NIOHTTPDecoderLimitConfiguration,
    errorHandling: Bool,
    sourceLocation: SourceLocation
) throws {
    let value = String(repeating: "x", count: decoderLimitConfiguration.maxHeaderFieldSize + 1)
    let error = #expect(throws: HTTPParserError.self, sourceLocation: sourceLocation) {
        try channel.writeInbound(ByteBuffer(string: "GET / HTTP/1.1\r\nX-Hdr: \(value)\r\n\r\n"))
    }
    #expect(error == .headerOverflow, sourceLocation: sourceLocation)
    let errorResponse = try channel.readOutbound(as: ByteBuffer.self)
    if errorHandling {
        let response = try #require(errorResponse, sourceLocation: sourceLocation)
        #expect(String(buffer: response).hasPrefix("HTTP/1.1 400"), sourceLocation: sourceLocation)
    } else {
        #expect(errorResponse == nil, sourceLocation: sourceLocation)
    }
    _ = try? channel.finish()
}

/// The settings required by `expectPipeline`.
private protocol PipelineConfiguration {
    init()

    var pipeliningAssistance: Bool { get set }
    var errorHandling: Bool { get set }
    var outboundHeaderValidation: Bool { get set }
    var encoderConfiguration: HTTPResponseEncoder.Configuration { get set }
    var decoderLimitConfiguration: NIOHTTPDecoderLimitConfiguration { get set }

    mutating func setServerUpgrade(_ upgrade: NIOHTTPServerUpgradeSendableConfiguration)
}

extension PipelineConfiguration {
    fileprivate mutating func apply(_ options: HTTPServerPipelineSetupTests.Options) {
        self.pipeliningAssistance = options.pipeliningAssistance
        self.errorHandling = options.errorHandling
        self.outboundHeaderValidation = options.outboundHeaderValidation
        self.encoderConfiguration.automaticallySetFramingHeaders = options.automaticallySetFramingHeaders
        if options.customDecoderLimits {
            self.decoderLimitConfiguration.maxHeaderFieldSize = 128
        }
        if options.serverUpgrade {
            self.setServerUpgrade((upgraders: [TestUpgrader()], completionHandler: { _ in }))
        }
    }
}

extension NIOHTTPServerPipelineConfiguration: PipelineConfiguration {
    fileprivate mutating func setServerUpgrade(_ upgrade: NIOHTTPServerUpgradeSendableConfiguration) {
        self.serverUpgrade = .init(upgraders: upgrade.upgraders, completionHandler: upgrade.completionHandler)
    }
}

extension NIOHTTPServerPipelineSynchronousConfiguration: PipelineConfiguration {
    fileprivate mutating func setServerUpgrade(_ upgrade: NIOHTTPServerUpgradeSendableConfiguration) {
        self.serverUpgrade = .init(upgraders: upgrade.upgraders, completionHandler: upgrade.completionHandler)
    }
}

private final class TestUpgrader: HTTPServerProtocolUpgrader, Sendable {
    /// A header added to the upgrade response so that tests can determine whether this upgrader handled the upgrade.
    static let testResponseHeader = (name: "test-upgrader", value: "upgraded")

    let supportedProtocol = "test"
    let requiredUpgradeHeaders: [String] = []

    func buildUpgradeResponse(
        channel: Channel,
        upgradeRequest: HTTPRequestHead,
        initialResponseHeaders: HTTPHeaders
    ) -> EventLoopFuture<HTTPHeaders> {
        var headers = initialResponseHeaders
        headers.add(name: Self.testResponseHeader.name, value: Self.testResponseHeader.value)
        return channel.eventLoop.makeSucceededFuture(headers)
    }

    func upgrade(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void> {
        context.eventLoop.makeSucceededVoidFuture()
    }
}

extension ChannelPipeline.SynchronousOperations {
    fileprivate func hasHandler<Handler: ChannelHandler>(_ of: Handler.Type) -> Bool {
        (try? self.handler(type: of)) != nil
    }
}
