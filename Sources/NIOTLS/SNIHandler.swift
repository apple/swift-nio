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

import NIO

/// The length of the TLS record header in bytes.
private let tlsRecordHeaderLength = 5

/// The content type identifier for a TLS handshake record.
private let tlsContentTypeHandshake: UInt8 = 22

/// The handshake type identifier for ClientHello records.
private let handshakeTypeClientHello: UInt8 = 1

/// The extension type for the SNI extension.
private let sniExtensionType: UInt16 = 0

/// The ServerName type for DNS host names.
private let sniHostNameType: UInt8 = 0

/// The result of the SNI parsing. If `hostname`, then the enum also
/// contains the hostname received in the SNI extension. If `fallback`,
/// then either we could not parse the SNI extension or it was not there
/// at all.
public enum SNIResult: Equatable {
    case fallback
    case hostname(String)
}

private enum InternalSNIErrors: Error {
    case invalidLengthInRecord
    case invalidRecord
    case recordIncomplete
}

private extension ByteBuffer {
    mutating func moveReaderIndexIfPossible(forwardBy distance: Int) throws {
        guard self.readableBytes >= distance else {
            throw InternalSNIErrors.invalidLengthInRecord
        }
        self.moveReaderIndex(forwardBy: distance)
    }

    mutating func readIntegerIfPossible<T: FixedWidthInteger>() throws -> T {
        guard let integer: T = self.readInteger() else {
            throw InternalSNIErrors.invalidLengthInRecord
        }
        return integer
    }
}

private extension Sequence where Element == UInt8 {
    func decodeStringValidatingASCII() -> String? {
        var bytesIterator = self.makeIterator()
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(self.underestimatedCount)
        var decoder = Unicode.ASCII.Parser()
        decode: while true {
            switch decoder.parseScalar(from: &bytesIterator) {
            case .valid(let v):
                scalars.append(Unicode.Scalar(v[0]))
            case .emptyInput:
                break decode
            case .error:
                return nil
            }
        }
        return String(scalars.map(Character.init))
    }
}

/// A channel handler that can be used to arbitrarily edit a channel
/// pipeline based on the hostname requested in the Server Name Indication
/// portion of the TLS Client Hello.
///
/// This handler is most commonly used when configuring TLS, to control
/// which certificates are going to be shown to the client. It can also be used
/// to ensure that only the resources required to serve a given virtual host are
/// actually present in the channel pipeline.
///
/// This handler does not depend on any specific TLS implementation. Instead, it parses
/// the Client Hello itself, directly. This allows it to be generic across all possible
/// TLS backends that can be used with NIO. It also allows for the pipeline change to
/// be done asynchronously, providing more flexibility about how the user configures the
/// pipeline.
public final class SNIHandler: ByteToMessageDecoder {
    public var cumulationBuffer: Optional<ByteBuffer>
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer

    private let completionHandler: (SNIResult) -> EventLoopFuture<Void>
    private var waitingForUser: Bool

    public init(sniCompleteHandler: @escaping (SNIResult) -> EventLoopFuture<Void>) {
        self.cumulationBuffer = nil
        self.completionHandler = sniCompleteHandler
        self.waitingForUser = false
    }

    public func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        context.fireChannelRead(NIOAny(buffer))
        return .needMoreData
    }

    // A note to maintainers: this method *never* returns `.continue`.
    public func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) -> DecodingState {
        // If we've asked the user to mutate the pipeline already, we're not interested in
        // this data. Keep waiting.
        if waitingForUser {
            return .needMoreData
        }

        let serverName: String?
        do {
            serverName = try parseTLSDataForServerName(buffer: buffer)
        } catch InternalSNIErrors.recordIncomplete {
            // Nothing bad here, we just don't have enough data.
            return .needMoreData
        } catch {
            // Some error occurred. Fall back and let the TLS stack
            // handle it.
            sniComplete(result: .fallback, context: context)
            return .needMoreData
        }

        if let serverName = serverName {
            sniComplete(result: .hostname(serverName), context: context)
        } else {
            sniComplete(result: .fallback, context: context)
        }
        return .needMoreData
    }

    /// Given a buffer of data that may contain a TLS Client Hello, parses the buffer looking for
    /// a server name extension. If it can be found, returns the host name in that extension. If
    /// no host name or extension is present, returns nil. If an error is encountered, throws. If
    /// there is not enough data in the buffer yet, throws recordIncomplete.
    private func parseTLSDataForServerName(buffer: ByteBuffer) throws -> String? {
        // We're taking advantage of value semantics here: this copy of the buffer will reference
        // the same underlying storage as the one we were passed, but any changes to it will not
        // be reflected in the outer buffer. That saves us from needing to maintain offsets
        // manually in this code. Thanks, Swift!
        var tempBuffer = buffer

        // First, parse the header.
        let contentLength = try parseRecordHeader(buffer: &tempBuffer)
        guard tempBuffer.readableBytes >= contentLength else {
            throw InternalSNIErrors.recordIncomplete
        }

        // At this point we know we have enough, at least according to the outer layer. We now want to
        // take a slice of our temp buffer so that we can make confident assertions about
        // all of the length. This also prevents us messing stuff up.
        //
        // From this point onwards if we don't have enough data to satisfy a read, this is an error and
        // we will fall back to let the upper layers handle it.
        tempBuffer = tempBuffer.getSlice(at: tempBuffer.readerIndex, length: Int(contentLength))! // length check above

        // Now parse the handshake header. If the length of the handshake message is not exactly the
        // length of this record, something has gone wrong and we should give up.
        let handshakeLength = try parseHandshakeHeader(buffer: &tempBuffer)
        guard tempBuffer.readableBytes == handshakeLength else {
            throw InternalSNIErrors.invalidRecord
        }

        // Now parse the client hello header. If the remaining length, which should be entirely extensions,
        // is not exactly the length of this record, something has gone wrong and we should give up.
        let extensionsLength = try parseClientHelloHeader(buffer: &tempBuffer)
        guard tempBuffer.readableBytes == extensionsLength else {
            throw InternalSNIErrors.invalidLengthInRecord
        }

        return try parseExtensionsForServerName(buffer: &tempBuffer)
    }

    /// Parses the TLS Record Header, ensuring that this is a handshake record and that
    /// the basics of the data appear to be correct.
    ///
    /// Returns the content-length of the record.
    private func parseRecordHeader(buffer: inout ByteBuffer) throws -> Int {
        // First, the obvious check: are there enough bytes for us to parse a complete
        // header? Because of this check we can use unsafe integer reads in the rest of
        // this function, as we'll only ever read tlsRecordHeaderLength number of bytes
        // here.
        guard buffer.readableBytes >= tlsRecordHeaderLength else {
            throw InternalSNIErrors.recordIncomplete
        }

        // Check the content type.
        let contentType: UInt8 = buffer.readInteger()! // length check above
        guard contentType == tlsContentTypeHandshake else {
            // Whatever this is, it's not a handshake message, so something has gone
            // wrong. We're going to fall back to the default handler here and let
            // that handler try to clean up this mess.
            throw InternalSNIErrors.invalidRecord
        }

        // Now, check the major version.
        let majorVersion: UInt8 = buffer.readInteger()! // length check above
        guard majorVersion == 3 else {
            // A major version of 3 is the major version used for SSLv3 and all subsequent versions
            // of the protocol. If that's not what this is, we don't know what's happening here.
            // Again, let the default handler make sense of this.
            throw InternalSNIErrors.invalidRecord
        }

        // Skip the minor version byte, then grab the content length.
        buffer.moveReaderIndex(forwardBy: 1)
        let contentLength: UInt16 = buffer.readInteger()! // length check above
        return Int(contentLength)
    }

    /// Parses the header of a TLS Handshake Record. Returns the expected number
    /// of bytes in the handshake body, or throws if this is not a ClientHello or
    /// has some other problem.
    private func parseHandshakeHeader(buffer: inout ByteBuffer) throws -> Int {
        // Ok, we're looking at a handshake message. That looks like this:
        // (see https://tools.ietf.org/html/rfc5246#section-7.4).
        //
        //      struct {
        //          HandshakeType msg_type;    /* handshake type */
        //          uint24 length;             /* bytes in message */
        //          select (HandshakeType) {
        //              case hello_request:       HelloRequest;
        //              case client_hello:        ClientHello;
        //              case server_hello:        ServerHello;
        //              case certificate:         Certificate;
        //              case server_key_exchange: ServerKeyExchange;
        //              case certificate_request: CertificateRequest;
        //              case server_hello_done:   ServerHelloDone;
        //              case certificate_verify:  CertificateVerify;
        //              case client_key_exchange: ClientKeyExchange;
        //              case finished:            Finished;
        //          } body;
        //      } Handshake;
        //
        // For the sake of our own happiness, we should check the handshake type and
        // validate its length. uint24 is a stupid type, so we have to play some
        // games here to get this to work. If we check that we have 4 bytes up-front
        // we can use unsafe reads: fewer than 4 bytes makes this message bogus.
        guard buffer.readableBytes >= 4 else {
            throw InternalSNIErrors.invalidRecord
        }

        let handshakeTypeAndLength: UInt32 = buffer.readInteger()!
        let handshakeType: UInt8 = UInt8((handshakeTypeAndLength & 0xFF000000) >> 24)
        let handshakeLength: UInt32 = handshakeTypeAndLength & 0x00FFFFFF
        guard handshakeType == handshakeTypeClientHello else {
            throw InternalSNIErrors.invalidRecord
        }

        return Int(handshakeLength)
    }

    /// Parses the header of the Client Hello record, and returns the total number of bytes
    /// used for extensions, or throws if the header is invalid or corrupted in some way.
    private func parseClientHelloHeader(buffer: inout ByteBuffer) throws -> Int {
        // Ok dear reader, you've made it this far, now you get to see the true face of the
        // ClientHello record. For context, this comes from
        // https://tools.ietf.org/html/rfc5246#section-7.4.1.2
        //
        //      struct {
        //          ProtocolVersion client_version;
        //          Random random;
        //          SessionID session_id;
        //          CipherSuite cipher_suites<2..2^16-2>;
        //          CompressionMethod compression_methods<1..2^8-1>;
        //          select (extensions_present) {
        //              case false:
        //                  struct {};
        //              case true:
        //                  Extension extensions<0..2^16-1>;
        //          };
        //      } ClientHello;
        //
        // We want to go straight down to the extensions, but we can't do that because
        // the SessionID, CipherSuite and CompressionMethod fields are variable length.
        // So we skip to them, and then parse. The ProtocolVersion field is two bytes:
        // the Random field is a 32-bit integer timestamp followed by a 28-byte array,
        // totalling 32 bytes. All-in-all we want to skip forward 34 bytes.
        // Unlike in other parsing methods we don't do an explicit length check here
        // because we don't know how long these fields are supposed to be: all we do know
        // is that the size of the ByteBuffer provides an upper bound on the size of this
        // header, so we use safe reads which will throw if the buffer is too short.
        try buffer.moveReaderIndexIfPossible(forwardBy: 34)

        let sessionIDLength: UInt8 = try buffer.readIntegerIfPossible()
        try buffer.moveReaderIndexIfPossible(forwardBy: Int(sessionIDLength))

        let cipherSuitesLength: UInt16 = try buffer.readIntegerIfPossible()
        try buffer.moveReaderIndexIfPossible(forwardBy: Int(cipherSuitesLength))

        let compressionMethodLength: UInt8 = try buffer.readIntegerIfPossible()
        try buffer.moveReaderIndexIfPossible(forwardBy: Int(compressionMethodLength))

        // Ok, we're at the extensions! Return the length.
        let extensionsLength: UInt16 = try buffer.readIntegerIfPossible()
        return Int(extensionsLength)
    }

    /// Parses the extensions portion of a Client Hello looking for a ServerName extension.
    /// Returns the host name in the ServerName extension, if any. If there is invalid data,
    /// throws. If no host name can be found, either due to the ServerName extension not containing
    /// one or due to no such extension being present, returns nil.
    private func parseExtensionsForServerName(buffer: inout ByteBuffer) throws -> String? {
        // The minimum number of bytes in an extension is 4: if we have fewer than that
        // we're done.
        while buffer.readableBytes >= 4 {
            let extensionType: UInt16 = try buffer.readIntegerIfPossible()
            let extensionLength: UInt16 = try buffer.readIntegerIfPossible()

            guard buffer.readableBytes >= extensionLength else {
                throw InternalSNIErrors.invalidLengthInRecord
            }

            guard extensionType == sniExtensionType else {
                // Move forward by the length of this extension.
                try buffer.moveReaderIndexIfPossible(forwardBy: Int(extensionLength))
                continue
            }

            // We've found the server name extension. It's possible a malicious client could attempt a confused
            // deputy attack by giving us contradictory lengths, so we again want to trim the bytebuffer down
            // so that we never read past the advertised length of this extension.
            buffer = buffer.getSlice(at: buffer.readerIndex, length: Int(extensionLength))!
            return try parseServerNameExtension(buffer: &buffer)
        }
        return nil
    }

    /// Parses a ServerName extension and returns the host name contained within, if any. If the extension
    /// is invalid for any reason, this will throw. If the extension does not contain a hostname, returns
    /// nil.
    private func parseServerNameExtension(buffer: inout ByteBuffer) throws -> String? {
        // The format of the SNI extension is here: https://tools.ietf.org/html/rfc6066#page-6
        //
        //      struct {
        //          NameType name_type;
        //          select (name_type) {
        //              case host_name: HostName;
        //          } name;
        //      } ServerName;
        //
        //      enum {
        //          host_name(0), (255)
        //      } NameType;
        //
        //      opaque HostName<1..2^16-1>;
        //
        //      struct {
        //          ServerName server_name_list<1..2^16-1>
        //      } ServerNameList;
        //
        // Note, however, that this is pretty academic. The SNI extension forbids multiple entries
        // in the ServerNameList that have the same NameType. As only one NameType is defined, we
        // could safely assume this list is one entry long.
        //
        // HOWEVER! It is a bad idea to write code that assumes that an extension point will
        // never be used, so let's try to parse this properly. We're going to parse only until we
        // find a host_name entry.
        //
        // This also uses unsafe reads: at this point, if the buffer is short then we're screwed.
        let nameBufferLength: UInt16 = try buffer.readIntegerIfPossible()
        guard buffer.readableBytes >= nameBufferLength else {
            throw InternalSNIErrors.invalidLengthInRecord
        }

        // We are never looking for another extension, so this is now all that we care about in the
        // world. Slice our way down to just that.
        buffer = buffer.getSlice(at: buffer.readerIndex, length: Int(nameBufferLength))!
        while buffer.readableBytes > 0 {
            let nameType: UInt8 = try buffer.readIntegerIfPossible()

            // From the RFC:
            // "For backward compatibility, all future data structures associated with new NameTypes
            // MUST begin with a 16-bit length field."
            let nameLength: UInt16 = try buffer.readIntegerIfPossible()
            guard nameType == sniHostNameType else {
                try buffer.moveReaderIndexIfPossible(forwardBy: Int(nameLength))
                continue
            }

            let hostname = buffer.withUnsafeReadableBytes { ptr -> String? in
                let nameLength = Int(nameLength)
                guard nameLength <= ptr.count else {
                    return nil
                }
                return UnsafeRawBufferPointer(rebasing: ptr.prefix(nameLength)).decodeStringValidatingASCII()
            }
            if let hostname = hostname {
                return hostname
            } else {
                throw InternalSNIErrors.invalidRecord
            }
        }
        return nil
    }

    /// Called when we either know the hostname being queried, or we know we can't
    /// work it out. Either way, we're done now.
    ///
    /// The processing here is as follows:
    ///
    /// 1. Call the user back with the result of the SNI lookup. At this point we're going to
    ///    allow them to tweak the channel pipeline as they see fit.
    /// 2. Wait for them to complete. In this time, we will continue to buffer all inbound
    ///    data.
    /// 3. When the user completes, remove ourselves from the pipeline. This will trigger the
    ///    ByteToMessageDecoder to automatically deliver the buffered bytes to the next handler
    ///    in the pipeline, which is now responsible for the work.
    private func sniComplete(result: SNIResult, context: ChannelHandlerContext) {
        waitingForUser = true
        completionHandler(result).whenSuccess {
            context.pipeline.removeHandler(context: context, promise: nil)
        }
    }
}
