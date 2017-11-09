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
    public mutating func readData(length: Int) -> Data? {
        precondition(length >= 0, "length must not be negative")
        guard self.readableBytes >= length else {
            return nil
        }
        let data = self.data(at: self.readerIndex, length: length)! /* must work, enough readable bytes */
        self.moveReaderIndex(forwardBy: length)
        return data
    }

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

    public func string(at index: Int, length: Int, encoding: String.Encoding) -> String? {
        guard let data = self.data(at: index, length: length) else {
            return nil
        }
        return String(data: data, encoding: encoding)
    }
}
