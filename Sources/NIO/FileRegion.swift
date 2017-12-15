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

/// A `FileRegion` represent a readable portion of a file which will be transferred.
///
/// Usually a `FileRegion` will allow the underlying transport to use `sendfile` to transfer its content and so allows transferring
/// the file content without copying it into user-space at all. If the actual transport implementation really can make use of sendfile
/// or if it will need to copy the content to user-space first and use `write` / `writev` is an implementation detail. That said
///  using `FileRegion` is the recommend way to transfer file content if possible.
///
/// One important note, depending your `ChannelPipeline` setup it may not be possible to use a `FileRegion` as a `ChannelHandler` may
/// need access to the bytes (in a `ByteBuffer`) to transform these.
public final class FileRegion {
    
    /// The file descriptor that is used by this `FileRegion`.
    public let descriptor: Int32
    
    /// `true` as long as this `FileRegion` was not closed yet and data can be read from it.
    private(set) public var open: Bool
    
    /// The current reader index of this `FileRegion`
    private(set) public var readerIndex: Int
    
    /// The end index of this `FileRegion`.
    public let endIndex: Int
    
    /// Create a new `FileRegion`.
    ///
    /// - parameters:
    ///     - descriptor: the file descriptor to use. The ownership of the file descriptor is transferred to this `FileRegion` and so it will be closed once `close` is called.
    ///     - readerIndex: the index (offset) on which the reading will start.
    ///     - endIndex: the index which represent the end of the readable portion.
    public init(descriptor: Int32, readerIndex: Int, endIndex: Int) {
        precondition(readerIndex <= endIndex, "readerIndex(\(readerIndex) must be <= endIndex(\(endIndex).")

        self.descriptor = descriptor
        self.readerIndex = readerIndex
        self.endIndex = endIndex
        self.open = true
    }
    
    /// Closes this `FileRegion` which will also close the underlying file descriptor.
    public func close() throws {
        guard self.open else {
            throw IOError(errnoCode: EBADF, reason: "can't close file (as it's not open anymore).")
        }
        
        try Posix.close(descriptor: self.descriptor)
        self.open = false
    }
    
    /// The number of readable bytes within this FileRegion (taking the `readerIndex` and `endIndex` into account).
    public var readableBytes: Int {
        return endIndex - readerIndex
    }
    
    /// Move the readerIndex forward.
    private func moveReaderIndex(forwardBy offset: Int) {
        let newIndex = self.readerIndex + offset
        assert(offset >= 0 && newIndex <= endIndex, "new readerIndex: \(newIndex), expected: range(0, \(endIndex))")
        self.readerIndex = newIndex
    }
    
    /// Provide a closure that will receive the `descriptor`, `readerIndex`, and `endIndex` and can consume some or all of the data from the `FileRegion`.
    ///
    /// - parameters:
    ///     - fn: the closure which will receive the `descriptor`,`readerIndex` and `endIndex`. The `readerIndex` is increased by the returned number of bytes if positive.
    /// - returns: the number of bytes read by the passed in closure.
    ///
    public func withMutableReader(_ fn: (Int32, Int, Int) throws -> Int) rethrows -> Int {
        let read = try fn(self.descriptor, self.readerIndex, self.endIndex)
        if read > 0 {
            moveReaderIndex(forwardBy: read)
        }
        return read
    }
}

extension FileRegion: CustomStringConvertible {
    public var description: String {
        return "FileRegion(descriptor: \(self.descriptor), readerIndex: \(self.readerIndex), endIndex: \(self.endIndex), open: \(self.open))"
    }
}

extension FileRegion {
    /// Create a new `FileRegion`.
    ///
    /// - parameters:
    ///     - file: the name of the file to open. The ownership of the file descriptor is transferred to this `FileRegion` and so it will be closed once `close` is called.
    ///     - readerIndex: the index (offset) on which the reading will start.
    ///     - endIndex: the index which represents the end of the readable portion.
    public convenience init(file: String, readerIndex: Int, endIndex: Int) throws {
        let fd = try Posix.open(file: file, oFlag: O_RDONLY)
        self.init(descriptor: Int32(fd), readerIndex: readerIndex, endIndex: endIndex)
    }
}
