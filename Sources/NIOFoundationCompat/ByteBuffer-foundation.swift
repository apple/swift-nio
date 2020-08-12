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
import Foundation


/// Errors that may be thrown by ByteBuffer methods that call into Foundation.
public enum ByteBufferFoundationError: Error {
    /// Attempting to encode the given string failed.
    case failedToEncodeString
}


/*
 * This is NIO's `NIOFoundationCompat` module which at the moment only adds `ByteBuffer` utility methods
 * for Foundation's `Data` type.
 *
 * The reason that it's not in the `NIO` module is that we don't want to have any direct Foundation dependencies
 * in `NIO` as Foundation is problematic for a few reasons:
 *
 * - its implementation is different on Linux and on macOS which means our macOS tests might be inaccurate
 * - on macOS Foundation is mostly written in ObjC which means the autorelease pool might get populated
 * - `swift-corelibs-foundation` (the OSS Foundation used on Linux) links the world which will prevent anyone from
 *   having static binaries. It can also cause problems in the choice of an SSL library as Foundation already brings
 *   the platforms OpenSSL in which might cause problems.
 */

extension ByteBuffer {
    /// Controls how bytes are transferred between `ByteBuffer` and other storage types.
    public enum ByteTransferStrategy {
        /// Force a copy of the bytes.
        case copy

        /// Do not copy the bytes if at all possible.
        case noCopy

        /// Use a heuristic to decide whether to copy the bytes or not.
        case automatic
    }

    // MARK: - Data APIs

    /// Read `length` bytes off this `ByteBuffer`, move the reader index forward by `length` bytes and return the result
    /// as `Data`.
    ///
    /// `ByteBuffer` will use a heuristic to decide whether to copy the bytes or whether to reference `ByteBuffer`'s
    /// underlying storage from the returned `Data` value. If you want manual control over the byte transferring
    /// behaviour, please use `readData(length:byteTransferStrategy:)`.
    ///
    /// - parameters:
    ///     - length: The number of bytes to be read from this `ByteBuffer`.
    /// - returns: A `Data` value containing `length` bytes or `nil` if there aren't at least `length` bytes readable.
    public mutating func readData(length: Int) -> Data? {
        return self.readData(length: length, byteTransferStrategy: .automatic)
    }


    /// Read `length` bytes off this `ByteBuffer`, move the reader index forward by `length` bytes and return the result
    /// as `Data`.
    ///
    /// - parameters:
    ///     - length: The number of bytes to be read from this `ByteBuffer`.
    ///     - byteTransferStrategy: Controls how to transfer the bytes. See `ByteTransferStrategy` for an explanation
    ///                             of the options.
    /// - returns: A `Data` value containing `length` bytes or `nil` if there aren't at least `length` bytes readable.
    public mutating func readData(length: Int, byteTransferStrategy: ByteTransferStrategy) -> Data? {
        return self.getData(at: self.readerIndex, length: length, byteTransferStrategy: byteTransferStrategy).map {
            self.moveReaderIndex(forwardBy: length)
            return $0
        }
    }

    /// Return `length` bytes starting at `index` and return the result as `Data`. This will not change the reader index.
    /// The selected bytes must be readable or else `nil` will be returned.
    ///
    /// `ByteBuffer` will use a heuristic to decide whether to copy the bytes or whether to reference `ByteBuffer`'s
    /// underlying storage from the returned `Data` value. If you want manual control over the byte transferring
    /// behaviour, please use `getData(at:byteTransferStrategy:)`.
    ///
    /// - parameters:
    ///     - index: The starting index of the bytes of interest into the `ByteBuffer`
    ///     - length: The number of bytes of interest
    /// - returns: A `Data` value containing the bytes of interest or `nil` if the selected bytes are not readable.
    public func getData(at index: Int, length: Int) -> Data? {
        return self.getData(at: index, length: length, byteTransferStrategy: .automatic)
    }

    /// Return `length` bytes starting at `index` and return the result as `Data`. This will not change the reader index.
    /// The selected bytes must be readable or else `nil` will be returned.
    ///
    /// - parameters:
    ///     - index: The starting index of the bytes of interest into the `ByteBuffer`
    ///     - length: The number of bytes of interest
    ///     - byteTransferStrategy: Controls how to transfer the bytes. See `ByteTransferStrategy` for an explanation
    ///                             of the options.
    /// - returns: A `Data` value containing the bytes of interest or `nil` if the selected bytes are not readable.
    public func getData(at index0: Int, length: Int, byteTransferStrategy: ByteTransferStrategy) -> Data? {
        let index = index0 - self.readerIndex
        guard index >= 0 && length >= 0 && index <= self.readableBytes - length else {
            return nil
        }
        let doCopy: Bool
        switch byteTransferStrategy {
        case .copy:
            doCopy = true
        case .noCopy:
            doCopy = false
        case .automatic:
            doCopy = length <= 256*1024
        }

        return self.withUnsafeReadableBytesWithStorageManagement { ptr, storageRef in
            if doCopy {
                return Data(bytes: UnsafeMutableRawPointer(mutating: ptr.baseAddress!.advanced(by: index)),
                            count: Int(length))
            } else {
                _ = storageRef.retain()
                return Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: ptr.baseAddress!.advanced(by: index)),
                            count: Int(length),
                            deallocator: .custom { _, _ in storageRef.release() })
            }
        }
    }

    // MARK: - Foundation String APIs

    /// Get a `String` decoding `length` bytes starting at `index` with `encoding`. This will not change the reader index.
    /// The selected bytes must be readable or else `nil` will be returned.
    ///
    /// - parameters:
    ///     - index: The starting index of the bytes of interest into the `ByteBuffer`.
    ///     - length: The number of bytes of interest.
    ///     - encoding: The `String` encoding to be used.
    /// - returns: A `String` value containing the bytes of interest or `nil` if the selected bytes are not readable or
    ///            cannot be decoded with the given encoding.
    public func getString(at index: Int, length: Int, encoding: String.Encoding) -> String? {
        guard let data = self.getData(at: index, length: length) else {
            return nil
        }
        return String(data: data, encoding: encoding)
    }

    /// Read a `String` decoding `length` bytes with `encoding` from the `readerIndex`, moving the `readerIndex` appropriately.
    ///
    /// - parameters:
    ///     - length: The number of bytes to read.
    ///     - encoding: The `String` encoding to be used.
    /// - returns: A `String` value containing the bytes of interest or `nil` if the `ByteBuffer` doesn't contain enough bytes, or
    ///     if those bytes cannot be decoded with the given encoding.
    public mutating func readString(length: Int, encoding: String.Encoding) -> String? {
        guard length <= self.readableBytes else {
            return nil
        }

        guard let string = self.getString(at: self.readerIndex, length: length, encoding: encoding) else {
            return nil
        }
        self.moveReaderIndex(forwardBy: length)
        return string
    }

    /// Write `string` into this `ByteBuffer` using the encoding `encoding`, moving the writer index forward appropriately.
    ///
    /// - parameters:
    ///     - string: The string to write.
    ///     - encoding: The encoding to use to encode the string.
    /// - returns: The number of bytes written.
    @discardableResult
    public mutating func writeString(_ string: String, encoding: String.Encoding) throws -> Int {
        let written = try self.setString(string, encoding: encoding, at: self.writerIndex)
        self.moveWriterIndex(forwardBy: written)
        return written
    }

    /// Write `string` into this `ByteBuffer` at `index` using the encoding `encoding`. Does not move the writer index.
    ///
    /// - parameters:
    ///     - string: The string to write.
    ///     - encoding: The encoding to use to encode the string.
    ///     - index: The index for the first serialized byte.
    /// - returns: The number of bytes written.
    @discardableResult
    public mutating func setString(_ string: String, encoding: String.Encoding, at index: Int) throws -> Int {
        guard let data = string.data(using: encoding) else {
            throw ByteBufferFoundationError.failedToEncodeString
        }
        return self.setBytes(data, at: index)
    }

    public init(data: Data) {
        self = ByteBufferAllocator().buffer(data: data)
    }

    // MARK: ContiguousBytes and DataProtocol
    /// Write `bytes` into this `ByteBuffer` at the writer index, moving the writer index forward appropriately.
    ///
    /// - parameters:
    ///     - bytes: The bytes to write.
    /// - returns: The number of bytes written.
    @inlinable
    @discardableResult
    public mutating func writeContiguousBytes<Bytes: ContiguousBytes>(_ bytes: Bytes) -> Int {
        let written = self.setContiguousBytes(bytes, at: self.writerIndex)
        self.moveWriterIndex(forwardBy: written)
        return written
    }

    /// Write `bytes` into this `ByteBuffer` at `index`. Does not move the writer index.
    ///
    /// - parameters:
    ///     - bytes: The bytes to write.
    ///     - index: The index for the first byte.
    /// - returns: The number of bytes written.
    @inlinable
    @discardableResult
    public mutating func setContiguousBytes<Bytes: ContiguousBytes>(_ bytes: Bytes, at index: Int) -> Int {
        return bytes.withUnsafeBytes { bufferPointer in
            self.setBytes(bufferPointer, at: index)
        }
    }

    /// Write the bytes of `data` into this `ByteBuffer` at the writer index, moving the writer index forward appropriately.
    ///
    /// - parameters:
    ///     - data: The data to write.
    /// - returns: The number of bytes written.
    @inlinable
    @discardableResult
    public mutating func writeData<D: DataProtocol>(_ data: D) -> Int {
        let written = self.setData(data, at: self.writerIndex)
        self.moveWriterIndex(forwardBy: written)
        return written
    }

    /// Write the bytes of `data` into this `ByteBuffer` at `index`. Does not move the writer index.
    ///
    /// - parameters:
    ///     - data: The data to write.
    ///     - index: The index for the first byte.
    /// - returns: The number of bytes written.
    @inlinable
    @discardableResult
    public mutating func setData<D: DataProtocol>(_ data: D, at index: Int) -> Int {
        // DataProtocol refines RandomAccessCollection, so getting `count` must be O(1). This avoids
        // intermediate allocations in the awkward case by ensuring we definitely have sufficient
        // space for these writes.
        self.reserveCapacity(minimumWritableBytes: data.count)

        var written = 0
        for region in data.regions {
            written += self.setContiguousBytes(region, at: index + written)
        }
        return written
    }
}

extension ByteBufferAllocator {
    /// Create a fresh `ByteBuffer` containing the bytes contained in the given `Data`.
    ///
    /// This will allocate a new `ByteBuffer` with enough space to fit the bytes of the `Data` and potentially
    /// some extra space using Swift's default allocator.
    public func buffer(data: Data) -> ByteBuffer {
        var buffer = self.buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }
}

// MARK: - Conformances
extension ByteBufferView: ContiguousBytes {}

extension ByteBufferView: DataProtocol {
    public typealias Regions = CollectionOfOne<ByteBufferView>

    public var regions: CollectionOfOne<ByteBufferView> {
        return .init(self)
    }
}

extension ByteBufferView: MutableDataProtocol {}

// MARK: - Data
extension Data {
    
    /// Creates a `Data` from a given `ByteBuffer`. The entire readable portion of the buffer will be read.
    /// - parameter buffer: The buffer to read.
    public init(buffer: ByteBuffer, byteTransferStrategy: ByteBuffer.ByteTransferStrategy = .automatic) {
        var buffer = buffer
        self = buffer.readData(length: buffer.readableBytes, byteTransferStrategy: byteTransferStrategy)!
    }
    
}
