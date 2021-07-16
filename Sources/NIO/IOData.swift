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

/// `IOData` unifies standard SwiftNIO types that are raw bytes of data; currently `ByteBuffer` and `FileRegion`.
///
/// Many `ChannelHandler`s receive or emit bytes and in most cases this can be either a `ByteBuffer` or a `FileRegion`
/// from disk. To still form a well-typed `ChannelPipeline` such handlers should receive and emit value of type `IOData`.
public enum IOData {
    /// A `ByteBuffer`.
    case byteBuffer(ByteBuffer)

    /// A `FileRegion`.
    ///
    /// Sending a `FileRegion` through the `ChannelPipeline` using `write` can be useful because some `Channel`s can
    /// use `sendfile` to send a `FileRegion` more efficiently.
    case fileRegion(FileRegion)
}

/// `IOData` objects are comparable just like the values they wrap.
extension IOData: Equatable {}

/// `IOData` provide a number of readable bytes.
extension IOData {
    /// Returns the number of readable bytes in this `IOData`.
    public var readableBytes: Int {
        switch self {
        case .byteBuffer(let buf):
            return buf.readableBytes
        case .fileRegion(let region):
            return region.readableBytes
        }
    }

    /// Move the readerIndex forward by `offset`.
    public mutating func moveReaderIndex(forwardBy: Int) {
        switch self {
        case .byteBuffer(var buffer):
            buffer.moveReaderIndex(forwardBy: forwardBy)
            self = .byteBuffer(buffer)
        case .fileRegion(var fileRegion):
            fileRegion.moveReaderIndex(forwardBy: forwardBy)
            self = .fileRegion(fileRegion)
        }
    }
}

extension IOData: CustomStringConvertible {
    public var description: String {
        switch self {
        case .byteBuffer(let byteBuffer):
            return "IOData { \(byteBuffer) }"
        case .fileRegion(let fileRegion):
            return "IOData { \(fileRegion) }"
        }
    }
}
