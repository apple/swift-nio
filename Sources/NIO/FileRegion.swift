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

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    import Darwin
#elseif os(Linux)
    import Glibc
#endif

public final class FileRegion {
    public let descriptor: Int32
    private(set) public var open: Bool
    private(set) public var readerIndex: Int
    public let endIndex: Int
    
    public init(descriptor: Int32, readerIndex: Int, endIndex: Int) {
        self.descriptor = descriptor
        self.readerIndex = readerIndex
        self.endIndex = endIndex
        self.open = true
    }
    
    public func close() throws {
        guard self.open else {
            throw IOError(errnoCode: EBADF, reason: "can't close file (as it's not open anymore).")
        }
        
        try Posix.close(descriptor: self.descriptor)
        self.open = false
    }
    
    public var readableBytes: Int {
        return endIndex - readerIndex
    }
    
    private func moveReaderIndex(forwardBy offset: Int) {
        let newIndex = self.readerIndex + offset
        assert(offset >= 0 && newIndex <= endIndex, "new readerIndex: \(newIndex), expected: range(0, \(endIndex))")
        self.readerIndex = newIndex
    }
    
    public func withMutableReader(_ fn: (Int32, Int, Int) throws -> Int) rethrows -> Int {
        let read = try fn(self.descriptor, self.readerIndex, self.endIndex)
        if read > 0 {
            moveReaderIndex(forwardBy: read)
        }
        return read
    }
}

public extension FileRegion {
    public convenience init(file: String, readerIndex: Int, endIndex: Int) throws {
        let fd = try Posix.open(file: file, oFlag: O_RDONLY)
        self.init(descriptor: Int32(fd), readerIndex: readerIndex, endIndex: endIndex)
    }
}
