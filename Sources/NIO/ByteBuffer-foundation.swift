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

extension ByteBuffer {

    // MARK: Data APIs
    public mutating func readData(length: Int) -> Data? {
        guard self.readableBytes >= length else {
            return nil
        }
        let data = self.data(at: self.readerIndex, length: length)! /* must work, enough readable bytes */
        self.moveReaderIndex(forwardBy: length)
        return data
    }

    @discardableResult
    public mutating func write(data: Data) -> Int {
        let bytesWritten = self.set(data: data, at: self.writerIndex)
        self.moveWriterIndex(forwardBy: bytesWritten)
        return bytesWritten
    }

    @discardableResult
    public mutating func set(data: Data, at index: Int) -> Int {
        return data.withUnsafeBytes { ptr in
            self.set(bytes: UnsafeRawBufferPointer(start: ptr, count: data.count), at: index)
        }
    }

    public func data(at index: Int, length: Int) -> Data? {
        guard index + length <= self.capacity else {
            return nil
        }
        return self.withVeryUnsafeBytesWithStorageManagement { ptr, storageRef in
            _ = storageRef.retain()
            return Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: ptr.baseAddress!.advanced(by: index)),
                        count: Int(length),
                        deallocator: .custom { _, _ in storageRef.release() })
        }
    }
}
