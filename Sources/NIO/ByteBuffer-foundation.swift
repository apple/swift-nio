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

import struct Foundation.Data

extension Data: ContiguousCollection {
    public func withUnsafeBytes<R>(_ fn: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        return try self.withUnsafeBytes { (ptr: UnsafePointer<UInt8>) -> R in
            return try fn(UnsafeRawBufferPointer(start: ptr, count: self.count))
        }
    }
}

extension ByteBuffer {

    // MARK: Data APIs

    /// Read `length` bytes off this `ByteBuffer`, move the reader index forward by `length` bytes and return the result
    /// as `Data`.
    ///
    /// - parameters:
    ///     - length: The number of bytes to be read from this `ByteBuffer`.
    /// - returns: A `Data` value containing `length` bytes or `nil` if there aren't at least `length` bytes readable.
    public mutating func readData(length: Int) -> Data? {
        precondition(length >= 0, "length must not be negative")
        guard self.readableBytes >= length else {
            return nil
        }
        let data = self.data(at: self.readerIndex, length: length)! /* must work, enough readable bytes */
        self.moveReaderIndex(forwardBy: length)
        return data
    }

    /// Return `length` bytes starting at `index` and return the result as `Data`. This will not change the reader index.
    ///
    /// - parameters:
    ///     - index: The starting index of the bytes of interest into the `ByteBuffer`
    ///     - length: The number of bytes of interest
    /// - returns: A `Data` value containing the bytes of interest or `nil` if the `ByteBuffer` doesn't contain those bytes.
    public func data(at index: Int, length: Int) -> Data? {
        precondition(length >= 0, "length must not be negative")
        precondition(index >= 0, "index must not be negative")
        guard index <= self.capacity - length else {
            return nil
        }
        return self.withVeryUnsafeBytesWithStorageManagement { ptr, storageRef in
            _ = storageRef.retain()
            return Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: ptr.baseAddress!.advanced(by: index)),
                        count: Int(length),
                        deallocator: .custom { _, _ in storageRef.release() })
        }
    }

    /// Get a `String` decoding `length` bytes starting at `index` with `encoding`. This will not change the reader index.
    ///
    /// - parameters:
    ///     - index: The starting index of the bytes of interest into the `ByteBuffer`.
    ///     - length: The number of bytes of interest.
    ///     - encoding: The `String` encoding to be used.
    /// - returns: A `String` value containing the bytes of interest or `nil` if the `ByteBuffer` doesn't contain those bytes.
    public func string(at index: Int, length: Int, encoding: String.Encoding) -> String? {
        guard let data = self.data(at: index, length: length) else {
            return nil
        }
        return String(data: data, encoding: encoding)
    }
}
