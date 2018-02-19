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
@testable import NIO
import NIOFoundationCompat
import NIOTLS

private let libressl227HelloNoSni = """
FgMBATkBAAE1AwNqcHrXsRJKtLx2HC1BXLt+kAk7SnCMk8qK
QPmv7L3u7QAAmMwUzBPMFcAwwCzAKMAkwBTACgCjAJ8AawBq
ADkAOP+FAMQAwwCIAIcAgcAywC7AKsAmwA/ABQCdAD0ANQDA
AITAL8ArwCfAI8ATwAkAogCeAGcAQAAzADIAvgC9AEUARMAx
wC3AKcAlwA7ABACcADwALwC6AEHAEcAHwAzAAgAFAATAEsAI
ABYAE8ANwAMACgAVABIACQD/AQAAdAALAAQDAAECAAoAOgA4
AA4ADQAZABwACwAMABsAGAAJAAoAGgAWABcACAAGAAcAFAAV
AAQABQASABMAAQACAAMADwAQABEAIwAAAA0AJgAkBgEGAgYD
7+8FAQUCBQMEAQQCBAPu7u3tAwEDAgMDAgECAgID
"""

private let libressl227HelloWithSni = """
FgMBAU0BAAFJAwN/gCauChg0p2XhDp6z2+gRqMeyb5zfxBOW
dtGXsknrcAAAmMwUzBPMFcAwwCzAKMAkwBTACgCjAJ8AawBq
ADkAOP+FAMQAwwCIAIcAgcAywC7AKsAmwA/ABQCdAD0ANQDA
AITAL8ArwCfAI8ATwAkAogCeAGcAQAAzADIAvgC9AEUARMAx
wC3AKcAlwA7ABACcADwALwC6AEHAEcAHwAzAAgAFAATAEsAI
ABYAE8ANwAMACgAVABIACQD/AQAAiAAAABAADgAAC2h0dHBi
aW4ub3JnAAsABAMAAQIACgA6ADgADgANABkAHAALAAwAGwAY
AAkACgAaABYAFwAIAAYABwAUABUABAAFABIAEwABAAIAAwAP
ABAAEQAjAAAADQAmACQGAQYCBgPv7wUBBQIFAwQBBAIEA+7u
7e0DAQMCAwMCAQICAgM=
"""

private let openssl102HelloNoSni = """
FgMBAS8BAAErAwPmgeNB1uuTN/P5ZlOjLQMHjxgIotE2796Z
ILeQHLg/ZQAArMAwwCzAKMAkwBTACgClAKMAoQCfAGsAagBp
AGgAOQA4ADcANgCIAIcAhgCFwDLALsAqwCbAD8AFAJ0APQA1
AITAL8ArwCfAI8ATwAkApACiAKAAngBnAEAAPwA+ADMAMgAx
ADAAmgCZAJgAlwBFAEQAQwBCwDHALcApwCXADsAEAJwAPAAv
AJYAQQAHwBHAB8AMwAIABQAEwBLACAAWABMAEAANwA3AAwAK
AP8CAQAAVQALAAQDAAECAAoAHAAaABcAGQAcABsAGAAaABYA
DgANAAsADAAJAAoAIwAAAA0AIAAeBgEGAgYDBQEFAgUDBAEE
AgQDAwEDAgMDAgECAgIDAA8AAQE=
"""

private let openssl102HelloWithSni = """
FgMBAUMBAAE/AwO0rkxuVnE+GcBdNP2UJwTCVSi2H2NbIngp
eTzpoVc+kgAArMAwwCzAKMAkwBTACgClAKMAoQCfAGsAagBp
AGgAOQA4ADcANgCIAIcAhgCFwDLALsAqwCbAD8AFAJ0APQA1
AITAL8ArwCfAI8ATwAkApACiAKAAngBnAEAAPwA+ADMAMgAx
ADAAmgCZAJgAlwBFAEQAQwBCwDHALcApwCXADsAEAJwAPAAv
AJYAQQAHwBHAB8AMwAIABQAEwBLACAAWABMAEAANwA3AAwAK
AP8CAQAAaQAAABAADgAAC2h0dHBiaW4ub3JnAAsABAMAAQIA
CgAcABoAFwAZABwAGwAYABoAFgAOAA0ACwAMAAkACgAjAAAA
DQAgAB4GAQYCBgMFAQUCBQMEAQQCBAMDAQMCAwMCAQICAgMA
DwABAQ==
"""

private let curlWithSecureTransport = """
FgMBAL4BAAC6AwNZ54sY4KDX3NJ7JTk/ER+MdC3dT72bCG8P
wFcIw08qJAAARAD/wCzAK8AkwCPACsAJwAjAMMAvwCjAJ8AU
wBPAEgCfAJ4AawBnADkAMwAWAJ0AnAA9ADwANQAvAAoArwCu
AI0AjACLAQAATQAAABAADgAAC2h0dHBiaW4ub3JnAAoACAAG
ABcAGAAZAAsAAgEAAA0AEgAQBAECAQUBBgEEAwIDBQMGAwAF
AAUBAAAAAAASAAAAFwAA
"""

private let safariWithSecureTransport = """
FgMBAOEBAADdAwP1UKyAyXfMC35xny6EHejdgPt7aPoHdeQG
/1FuKmniSQAAKMAswCvAJMAjwArACcypwDDAL8AowCfAFMAT
zKgAnQCcAD0APAA1AC8BAACM/wEAAQAAAAAQAA4AAAtodHRw
YmluLm9yZwAXAAAADQAUABIEAwgEBAEFAwgFBQEIBgYBAgEA
BQAFAQAAAAAzdAAAABIAAAAQADAALgJoMgVoMi0xNgVoMi0x
NQVoMi0xNAhzcGR5LzMuMQZzcGR5LzMIaHR0cC8xLjEACwAC
AQAACgAIAAYAHQAXABg=
"""

private let chromeWithBoringSSL = """
FgMBAMIBAAC+AwMTXqvA3thIWxHtp1Fpf56+YmWbfaNxMO4f
DSUKnu6d/gAAHBoawCvAL8AswDDMqcyowBPAFACcAJ0ALwA1
AAoBAAB5qqoAAP8BAAEAAAAAEAAOAAALaHR0cGJpbi5vcmcA
FwAAACMAAAANABQAEgQDCAQEAQUDCAUFAQgGBgECAQAFAAUB
AAAAAAASAAAAEAAOAAwCaDIIaHR0cC8xLjF1UAAAAAsAAgEA
AAoACgAIWloAHQAXABjKygABAA==
"""

private let firefoxWithNSS = """
FgMBALcBAACzAwN6qgxS1T0PTzYdLZ+3CvMBosugW1anTOsO
blZjJ+/adgAAHsArwC/MqcyowCzAMMAKwAnAE8AUADMAOQAv
ADUACgEAAGwAAAAQAA4AAAtodHRwYmluLm9yZwAXAAD/AQAB
AAAKAAoACAAdABcAGAAZAAsAAgEAACMAAAAQAA4ADAJoMgho
dHRwLzEuMQAFAAUBAAAAAAANABgAFgQDBQMGAwgECAUIBgQB
BQEGAQIDAgE=
"""

private let alertFatalInternalError = "FQMDAAICUA=="

private let invalidTlsVersion = """
FgQAALcBAACzAwN6qgxS1T0PTzYdLZ+3CvMBosugW1anTOsO
blZjJ+/adgAAHsArwC/MqcyowCzAMMAKwAnAE8AUADMAOQAv
ADUACgEAAGwAAAAQAA4AAAtodHRwYmluLm9yZwAXAAD/AQAB
AAAKAAoACAAdABcAGAAZAAsAAgEAACMAAAAQAA4ADAJoMgho
dHRwLzEuMQAFAAUBAAAAAAANABgAFgQDBQMGAwgECAUIBgQB
BQEGAQIDAgE=
"""

private let clientKeyExchange = """
FgMDAJYQAACSkQQAR/1YL9kZ13n6OWVy6VMLqc++ZTHfZVlt
RlLYoziZSu7tKZ9UUMvZJ5BCcH3juFGM9wftZi0PIjKuRrBZ
erk++KawYtxuaIwDGwinj70hmUxB9jQSa0M9NXXNVHZWgMSX
YVj3N8SBAfmGbWQbH9uONzieFuVYwkmVEidIlE7A04gHP9id
Oy5Badfl6Ab5fDg=
"""

private let invalidHandshakeLength = """
FgMBALcBAQCzAwN6qgxS1T0PTzYdLZ+3CvMBosugW1anTOsO
blZjJ+/adgAAHsArwC/MqcyowCzAMMAKwAnAE8AUADMAOQAv
ADUACgEAAGwAAAAQAA4AAAtodHRwYmluLm9yZwAXAAD/AQAB
AAAKAAoACAAdABcAGAAZAAsAAgEAACMAAAAQAA4ADAJoMgho
dHRwLzEuMQAFAAUBAAAAAAANABgAFgQDBQMGAwgECAUIBgQB
BQEGAQIDAgE=
"""

private let invalidCipherSuitesLength = """
FgMBAU0BAAFJAwNyvld+G6aaYHyOf2Q6A5P7pFYdY9oWq6U/
lEvy1/7zGQDw/8wUzBPMFcAwwCzAKMAkwBTACgCjAJ8AawBq
ADkAOP+FAMQAwwCIAIcAgcAywC7AKsAmwA/ABQCdAD0ANQDA
AITAL8ArwCfAI8ATwAkAogCeAGcAQAAzADIAvgC9AEUARMAx
wC3AKcAlwA7ABACcADwALwC6AEHAEcAHwAzAAgAFAATAEsAI
ABYAE8ANwAMACgAVABIACQD/AQAAiAAAABAADgAAC2h0dHBi
aW4ub3JnAAsABAMAAQIACgA6ADgADgANABkAHAALAAwAGwAY
AAkACgAaABYAFwAIAAYABwAUABUABAAFABIAEwABAAIAAwAP
ABAAEQAjAAAADQAmACQGAQYCBgPv7wUBBQIFAwQBBAIEA+7u
7e0DAQMCAwMCAQICAgM=
"""

private let invalidCompressionLength = """
'FgMBAU0BAAFJAwNyvld+G6aaYHyOf2Q6A5P7pFYdY9oWq6U
/lEvy1/7zGQAAmMwUzBPMFcAwwCzAKMAkwBTACgCjAJ8AawB
qADkAOP+FAMQAwwCIAIcAgcAywC7AKsAmwA/ABQCdAD0ANQD
AAITAL8ArwCfAI8ATwAkAogCeAGcAQAAzADIAvgC9AEUARMA
xwC3AKcAlwA7ABACcADwALwC6AEHAEcAHwAzAAgAFAATAEsA
IABYAE8ANwAMACgAVABIACQD//wAAiAAAABAADgAAC2h0dHB
iaW4ub3JnAAsABAMAAQIACgA6ADgADgANABkAHAALAAwAGwA
YAAkACgAaABYAFwAIAAYABwAUABUABAAFABIAEwABAAIAAwA
PABAAEQAjAAAADQAmACQGAQYCBgPv7wUBBQIFAwQBBAIEA+7
u7e0DAQMCAwMCAQICAgM='
"""

private let invalidExtensionLength = """
FgMBAU0BAAFJAwNyvld+G6aaYHyOf2Q6A5P7pFYdY9oWq6U/
lEvy1/7zGQAAmMwUzBPMFcAwwCzAKMAkwBTACgCjAJ8AawBq
ADkAOP+FAMQAwwCIAIcAgcAywC7AKsAmwA/ABQCdAD0ANQDA
AITAL8ArwCfAI8ATwAkAogCeAGcAQAAzADIAvgC9AEUARMAx
wC3AKcAlwA7ABACcADwALwC6AEHAEcAHwAzAAgAFAATAEsAI
ABYAE8ANwAMACgAVABIACQD/AQDw/wAAABAADgAAC2h0dHBi
aW4ub3JnAAsABAMAAQIACgA6ADgADgANABkAHAALAAwAGwAY
AAkACgAaABYAFwAIAAYABwAUABUABAAFABIAEwABAAIAAwAP
ABAAEQAjAAAADQAmACQGAQYCBgPv7wUBBQIFAwQBBAIEA+7u
7e0DAQMCAwMCAQICAgM=
"""

private let invalidIndividualExtensionLength = """
FgMBAU0BAAFJAwNyvld+G6aaYHyOf2Q6A5P7pFYdY9oWq6U/
lEvy1/7zGQAAmMwUzBPMFcAwwCzAKMAkwBTACgCjAJ8AawBq
ADkAOP+FAMQAwwCIAIcAgcAywC7AKsAmwA/ABQCdAD0ANQDA
AITAL8ArwCfAI8ATwAkAogCeAGcAQAAzADIAvgC9AEUARMAx
wC3AKcAlwA7ABACcADwALwC6AEHAEcAHwAzAAgAFAATAEsAI
ABYAE8ANwAMACgAVABIACQD/AQAAiAAA8P8ADgAAC2h0dHBi
aW4ub3JnAAsABAMAAQIACgA6ADgADgANABkAHAALAAwAGwAY
AAkACgAaABYAFwAIAAYABwAUABUABAAFABIAEwABAAIAAwAP
ABAAEQAjAAAADQAmACQGAQYCBgPv7wUBBQIFAwQBBAIEA+7u
7e0DAQMCAwMCAQICAgM=
"""

private let unknownNameType = """
'FgMBAU0BAAFJAwNyvld+G6aaYHyOf2Q6A5P7pFYdY9oWq6U
/lEvy1/7zGQAAmMwUzBPMFcAwwCzAKMAkwBTACgCjAJ8AawB
qADkAOP+FAMQAwwCIAIcAgcAywC7AKsAmwA/ABQCdAD0ANQD
AAITAL8ArwCfAI8ATwAkAogCeAGcAQAAzADIAvgC9AEUARMA
xwC3AKcAlwA7ABACcADwALwC6AEHAEcAHwAzAAgAFAATAEsA
IABYAE8ANwAMACgAVABIACQD/AQAAiAAAABAADgEAC2h0dHB
iaW4ub3JnAAsABAMAAQIACgA6ADgADgANABkAHAALAAwAGwA
YAAkACgAaABYAFwAIAAYABwAUABUABAAFABIAEwABAAIAAwA
PABAAEQAjAAAADQAmACQGAQYCBgPv7wUBBQIFAwQBBAIEA+7
u7e0DAQMCAwMCAQICAgM=
"""

private let invalidNameLength = """
FgMBAU0BAAFJAwNyvld+G6aaYHyOf2Q6A5P7pFYdY9oWq6U/
lEvy1/7zGQAAmMwUzBPMFcAwwCzAKMAkwBTACgCjAJ8AawBq
ADkAOP+FAMQAwwCIAIcAgcAywC7AKsAmwA/ABQCdAD0ANQDA
AITAL8ArwCfAI8ATwAkAogCeAGcAQAAzADIAvgC9AEUARMAx
wC3AKcAlwA7ABACcADwALwC6AEHAEcAHwAzAAgAFAATAEsAI
ABYAE8ANwAMACgAVABIACQD/AQAAiAAAABAADgD/8Gh0dHBi
aW4ub3JnAAsABAMAAQIACgA6ADgADgANABkAHAALAAwAGwAY
AAkACgAaABYAFwAIAAYABwAUABUABAAFABIAEwABAAIAAwAP
ABAAEQAjAAAADQAmACQGAQYCBgPv7wUBBQIFAwQBBAIEA+7u
7e0DAQMCAwMCAQICAgM=
"""

private let invalidNameExtensionLength = """
FgMBAU0BAAFJAwNyvld+G6aaYHyOf2Q6A5P7pFYdY9oWq6U/
lEvy1/7zGQAAmMwUzBPMFcAwwCzAKMAkwBTACgCjAJ8AawBq
ADkAOP+FAMQAwwCIAIcAgcAywC7AKsAmwA/ABQCdAD0ANQDA
AITAL8ArwCfAI8ATwAkAogCeAGcAQAAzADIAvgC9AEUARMAx
wC3AKcAlwA7ABACcADwALwC6AEHAEcAHwAzAAgAFAATAEsAI
ABYAE8ANwAMACgAVABIACQD/AQAAiAAAABDw/wAAC2h0dHBi
aW4ub3JnAAsABAMAAQIACgA6ADgADgANABkAHAALAAwAGwAY
AAkACgAaABYAFwAIAAYABwAUABUABAAFABIAEwABAAIAAwAP
ABAAEQAjAAAADQAmACQGAQYCBgPv7wUBBQIFAwQBBAIEA+7u
7e0DAQMCAwMCAQICAgM=
"""

private let ludicrouslyTruncatedPacket = "FgMBAAEB"

private let fuzzingInputOne = "FgMAAAQAAgo="

internal extension ChannelPipeline {
    func contains(handler: ChannelHandler) throws -> Bool {
        do {
            _ = try self.context(handler: handler).wait()
            return true
        } catch ChannelPipelineError.notFound {
            return false
        }
    }
    func assertDoesNotContain(handler: ChannelHandler) throws {
        XCTAssertFalse(try contains(handler: handler))
    }

    func assertContains(handler: ChannelHandler) throws {
        XCTAssertTrue(try contains(handler: handler))
    }
}


class SniHandlerTest: XCTestCase {
    private func bufferForBase64String(string: String) -> ByteBuffer {
        let data = Data(base64Encoded: string, options: .ignoreUnknownCharacters)!
        let allocator = ByteBufferAllocator()
        var buffer = allocator.buffer(capacity: data.count)
        buffer.write(bytes: data)
        return buffer
    }

    /// Drip-feeds the client hello in one byte at a time.
    /// Also asserts that the channel handler does not remove itself from
    /// the pipeline or emit its buffered data until the future fires.
    func dripFeedHello(clientHello: String, expectedResult: SniResult) throws {
        var called = false
        var buffer = bufferForBase64String(string: clientHello)
        let channel = EmbeddedChannel()
        let loop = channel.eventLoop as! EmbeddedEventLoop
        let continuePromise: EventLoopPromise<Void> = loop.newPromise()

        let handler = SniHandler { result in
            XCTAssertEqual(expectedResult, result)
            called = true
            return continuePromise.futureResult
        }

        try channel.pipeline.add(handler: handler).wait()

        // The handler will run when the last byte of the extension data is sent.
        // We don't know when that is, so don't try to predict it. However,
        // for this entire time the handler should remain in the pipeline and not
        // forward on any data.
        while buffer.readableBytes > 0 {
            let writeableData = buffer.readSlice(length: 1)!
            try channel.writeInbound(writeableData)
            loop.run()

            XCTAssertNil(channel.readInbound())
            try channel.pipeline.assertContains(handler: handler)
        }

        // The callback should now have fired, but the handler should still not have
        // sent on any data and should still be in the pipeline.
        XCTAssertTrue(called)
        XCTAssertNil(channel.readInbound())
        try channel.pipeline.assertContains(handler: handler)

        // Now we're going to complete the promise and run the loop. This should cause the complete
        // ClientHello to be sent on, and the SniHandler to be removed from the pipeline.
        continuePromise.succeed(result: ())
        loop.run()

        let writtenBuffer: ByteBuffer = channel.readInbound()!
        let writtenData = writtenBuffer.getData(at: writtenBuffer.readerIndex, length: writtenBuffer.readableBytes)
        let expectedData = Data(base64Encoded: clientHello, options: .ignoreUnknownCharacters)!
        XCTAssertEqual(writtenData, expectedData)

        try channel.pipeline.assertDoesNotContain(handler: handler)

        XCTAssertFalse(try channel.finish())
    }

    /// Blasts the client hello in as a single string. This is not expected to reveal bugs
    /// that the drip feed doesn't hit: it just helps to find more gross logic bugs.
    func blastHello(clientHello: String, expectedResult: SniResult) throws {
        var called = false
        let buffer = bufferForBase64String(string: clientHello)
        let channel = EmbeddedChannel()
        let loop = channel.eventLoop as! EmbeddedEventLoop
        let continuePromise: EventLoopPromise<Void> = loop.newPromise()

        let handler = SniHandler { result in
            XCTAssertEqual(expectedResult, result)
            called = true
            return continuePromise.futureResult
        }

        try channel.pipeline.add(handler: handler).wait()

        // Ok, let's go.
        try channel.writeInbound(buffer)
        loop.run()

        // The callback should have fired, but the handler should not have
        // sent on any data and should still be in the pipeline.
        XCTAssertTrue(called)
        XCTAssertNil(channel.readInbound() as ByteBuffer?)
        try channel.pipeline.assertContains(handler: handler)

        // Now we're going to complete the promise and run the loop. This should cause the complete
        // ClientHello to be sent on, and the SniHandler to be removed from the pipeline.
        continuePromise.succeed(result: ())
        loop.run()

        let writtenBuffer: ByteBuffer? = channel.readInbound()
        if let writtenBuffer = writtenBuffer {
            let writtenData = writtenBuffer.getData(at: writtenBuffer.readerIndex, length: writtenBuffer.readableBytes)
            let expectedData = Data(base64Encoded: clientHello, options: .ignoreUnknownCharacters)!
            XCTAssertEqual(writtenData, expectedData)
        } else {
            XCTFail("no inbound data available")
        }

        try channel.pipeline.assertDoesNotContain(handler: handler)
        XCTAssertFalse(try channel.finish())
    }

    func assertIncompleteInput(clientHello: String) throws {
        let buffer = bufferForBase64String(string: clientHello)
        let channel = EmbeddedChannel()
        let loop = channel.eventLoop as! EmbeddedEventLoop

        let handler = SniHandler { result in
            XCTFail("Handler was called")
            return loop.newSucceededFuture(result: ())
        }

        try channel.pipeline.add(handler: handler).wait()

        // Ok, let's go.
        try channel.writeInbound(buffer)
        loop.run()

        // The callback should not have fired, the handler should still be in the pipeline,
        // and no data should have been written.
        XCTAssertNil(channel.readInbound() as ByteBuffer?)
        try channel.pipeline.assertContains(handler: handler)

        XCTAssertNoThrow(try channel.finish())
    }

    func testLibre227NoSniDripFeed() throws {
        try dripFeedHello(clientHello: libressl227HelloNoSni, expectedResult: .fallback)
    }

    func testLibre227WithSniDripFeed() throws {
        try dripFeedHello(clientHello: libressl227HelloWithSni, expectedResult: .hostname("httpbin.org"))
    }

    func testOpenSSL102NoSniDripFeed() throws {
        try dripFeedHello(clientHello: openssl102HelloNoSni, expectedResult: .fallback)
    }

    func testOpenSSL102WithSniDripFeed() throws {
        try dripFeedHello(clientHello: openssl102HelloWithSni, expectedResult: .hostname("httpbin.org"))
    }

    func testCurlSecureTransportDripFeed() throws {
        try dripFeedHello(clientHello: curlWithSecureTransport, expectedResult: .hostname("httpbin.org"))
    }

    func testSafariDripFeed() throws {
        try dripFeedHello(clientHello: safariWithSecureTransport, expectedResult: .hostname("httpbin.org"))
    }

    func testChromeDripFeed() throws {
        try dripFeedHello(clientHello: chromeWithBoringSSL, expectedResult: .hostname("httpbin.org"))
    }

    func testFirefoxDripFeed() throws {
        try dripFeedHello(clientHello: firefoxWithNSS, expectedResult: .hostname("httpbin.org"))
    }

    func testLibre227NoSniBlast() throws {
        try blastHello(clientHello: libressl227HelloNoSni, expectedResult: .fallback)
    }

    func testLibre227WithSniBlast() throws {
        try blastHello(clientHello: libressl227HelloWithSni, expectedResult: .hostname("httpbin.org"))
    }

    func testOpenSSL102NoSniBlast() throws {
        try blastHello(clientHello: openssl102HelloNoSni, expectedResult: .fallback)
    }

    func testOpenSSL102WithSniBlast() throws {
        try blastHello(clientHello: openssl102HelloWithSni, expectedResult: .hostname("httpbin.org"))
    }

    func testCurlSecureTransportBlast() throws {
        try blastHello(clientHello: curlWithSecureTransport, expectedResult: .hostname("httpbin.org"))
    }

    func testSafariBlast() throws {
        try blastHello(clientHello: safariWithSecureTransport, expectedResult: .hostname("httpbin.org"))
    }

    func testChromeBlast() throws {
        try blastHello(clientHello: chromeWithBoringSSL, expectedResult: .hostname("httpbin.org"))
    }

    func testFirefoxBlast() throws {
        try blastHello(clientHello: firefoxWithNSS, expectedResult: .hostname("httpbin.org"))
    }

    func testIgnoresUnknownRecordTypes() throws {
        try blastHello(clientHello: alertFatalInternalError, expectedResult: .fallback)
    }

    func testIgnoresUnknownTlsVersions() throws {
        try blastHello(clientHello: invalidTlsVersion, expectedResult: .fallback)
    }

    func testIgnoresNonClientHelloHandshakeMessages() throws {
        try blastHello(clientHello: clientKeyExchange, expectedResult: .fallback)
    }

    func testIgnoresInvalidHandshakeLength() throws {
        try blastHello(clientHello: invalidHandshakeLength, expectedResult: .fallback)
    }

    func testIgnoresInvalidCipherSuiteLength() throws {
        try blastHello(clientHello: invalidCipherSuitesLength, expectedResult: .fallback)
    }

    func testIgnoresInvalidCompressionLength() throws {
        try blastHello(clientHello: invalidCompressionLength, expectedResult: .fallback)
    }

    func testIgnoresInvalidExtensionLength() throws {
        try blastHello(clientHello: invalidExtensionLength, expectedResult: .fallback)
    }

    func testIgnoresInvalidIndividualExtensionLength() throws {
        try blastHello(clientHello: invalidIndividualExtensionLength, expectedResult: .fallback)
    }

    func testIgnoresUnknownNameType() throws {
        try blastHello(clientHello: unknownNameType, expectedResult: .fallback)
    }

    func testIgnoresInvalidNameLength() throws {
        try blastHello(clientHello: invalidNameLength, expectedResult: .fallback)
    }

    func testIgnoresInvalidNameExtensionLength() throws {
        try blastHello(clientHello: invalidNameExtensionLength, expectedResult: .fallback)
    }

    func testLudicrouslyTruncatedPacket() throws {
        try blastHello(clientHello: ludicrouslyTruncatedPacket, expectedResult: .fallback)
    }

    func testFuzzingInputOne() throws {
        try assertIncompleteInput(clientHello: fuzzingInputOne)
    }
}
