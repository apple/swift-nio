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

import NIOConcurrencyHelpers
import Dispatch

/// `NonBlockingFileIO` is a helper that allows you to read files without blocking the calling thread.
///
/// It is worth noting that `kqueue`, `epoll` or `poll` returning claiming a file is readable does not mean that the
/// data is already available in the kernel's memory. In other words, a `read` from a file can still block even if
/// reported as readable. This behaviour is also documented behaviour:
///
///  - [`poll`](http://pubs.opengroup.org/onlinepubs/009695399/functions/poll.html): "Regular files shall always poll TRUE for reading and writing."
///  - [`epoll`](http://man7.org/linux/man-pages/man7/epoll.7.html): "epoll is simply a faster poll(2), and can be used wherever the latter is used since it shares the same semantics."
///  - [`kqueue`](https://www.freebsd.org/cgi/man.cgi?query=kqueue&sektion=2): "Returns when the file pointer is not at the end of file."
///
/// `NonBlockingFileIO` helps to work around this issue by maintaining its own thread pool that is used to read the data
/// from the files into memory. It will then hand the (in-memory) data back which makes it available without the possibility
/// of blocking.
public struct NonBlockingFileIO {
    /// The default and recommended size for `NonBlockingFileIO`'s thread pool.
    public static let defaultThreadPoolSize = 2

    /// The default and recommended chunk size.
    public static let defaultChunkSize = 128*1024

    /// `NonBlockingFileIO` errors.
    public enum Error: Swift.Error {
        /// `NonBlockingFileIO` is meant to be used with file descriptors that are set to the default (blocking) mode.
        /// It doesn't make sense to use it with a file descriptor where `O_NONBLOCK` is set therefore this error is
        /// raised when that was requested.
        case descriptorSetToNonBlocking
    }

    private let threadPool: BlockingIOThreadPool

    /// Initialize a `NonBlockingFileIO` which uses the `BlockingIOThreadPool`.
    ///
    /// - parameters:
    ///   - threadPool: The `BlockingIOThreadPool` that will be used for all the IO.
    public init(threadPool: BlockingIOThreadPool) {
        self.threadPool = threadPool
    }

    /// Read a `FileRegion` in chunks of `chunkSize` bytes on `NonBlockingFileIO`'s private thread
    /// pool which is separate from any `EventLoop` thread.
    ///
    /// `chunkHandler` will be called on `eventLoop` for every chunk that was read. Assuming `fileRegion.readableBytes` is greater than
    /// zero and there are enough bytes available `chunkHandler` will be called `1 + |_ fileRegion.readableBytes / chunkSize _|`
    /// times, delivering `chunkSize` bytes each time. If less than `fileRegion.readableBytes` bytes can be read from the file,
    /// `chunkHandler` will be called less often with the last invocation possibly being of less than `chunkSize` bytes.
    ///
    /// The allocation and reading of a subsequent chunk will only be attempted when `chunkHandler` succeeds.
    ///
    /// - parameters:
    ///   - fileRegion: The file region to read.
    ///   - chunkSize: The size of the individual chunks to deliver.
    ///   - allocator: A `ByteBufferAllocator` used to allocate space for the chunks.
    ///   - eventLoop: The `EventLoop` to call `chunkHandler` on.
    ///   - chunkHandler: Called for every chunk read. The next chunk will be read upon successful completion of the returned `EventLoopFuture`. If the returned `EventLoopFuture` fails, the overall operation is aborted.
    /// - returns: An `EventLoopFuture` which is the result of the overall operation. If either the reading of `fileHandle` or `chunkHandler` fails, the `EventLoopFuture` will fail too. If the reading of `fileHandle` as well as `chunkHandler` always succeeded, the `EventLoopFuture` will succeed too.
    public func readChunked(fileRegion: FileRegion,
                            chunkSize: Int = NonBlockingFileIO.defaultChunkSize,
                            allocator: ByteBufferAllocator,
                            eventLoop: EventLoop,
                            chunkHandler: @escaping (ByteBuffer) -> EventLoopFuture<Void>) -> EventLoopFuture<Void> {
        do {
            let readableBytes = fileRegion.readableBytes
            try fileRegion.fileHandle.withUnsafeFileDescriptor { descriptor in
                _ = try Posix.lseek(descriptor: descriptor, offset: off_t(fileRegion.readerIndex), whence: SEEK_SET)
            }
            return self.readChunked(fileHandle: fileRegion.fileHandle,
                                    byteCount: readableBytes,
                                    chunkSize: chunkSize,
                                    allocator: allocator,
                                    eventLoop: eventLoop,
                                    chunkHandler: chunkHandler)
        } catch {
            return eventLoop.newFailedFuture(error: error)
        }
    }

    /// Read `byteCount` bytes in chunks of `chunkSize` bytes from `fileHandle` in `NonBlockingFileIO`'s private thread
    /// pool which is separate from any `EventLoop` thread.
    ///
    /// `chunkHandler` will be called on `eventLoop` for every chunk that was read. Assuming `byteCount` is greater than
    /// zero and there are enough bytes available `chunkHandler` will be called `1 + |_ byteCount / chunkSize _|`
    /// times, delivering `chunkSize` bytes each time. If less than `byteCount` bytes can be read from `descriptor`,
    /// `chunkHandler` will be called less often with the last invocation possibly being of less than `chunkSize` bytes.
    ///
    /// The allocation and reading of a subsequent chunk will only be attempted when `chunkHandler` succeeds.
    ///
    /// - note: `readChunked(fileRegion:chunkSize:allocator:eventLoop:chunkHandler:)` should be preferred as it uses `FileRegion` object instead of raw `FileHandle`s.
    ///
    /// - parameters:
    ///   - fileHandle: The `FileHandle` to read from.
    ///   - byteCount: The number of bytes to read from `fileHandle`.
    ///   - chunkSize: The size of the individual chunks to deliver.
    ///   - allocator: A `ByteBufferAllocator` used to allocate space for the chunks.
    ///   - eventLoop: The `EventLoop` to call `chunkHandler` on.
    ///   - chunkHandler: Called for every chunk read. The next chunk will be read upon successful completion of the returned `EventLoopFuture`. If the returned `EventLoopFuture` fails, the overall operation is aborted.
    /// - returns: An `EventLoopFuture` which is the result of the overall operation. If either the reading of `fileHandle` or `chunkHandler` fails, the `EventLoopFuture` will fail too. If the reading of `fileHandle` as well as `chunkHandler` always succeeded, the `EventLoopFuture` will succeed too.
    public func readChunked(fileHandle: FileHandle,
                            byteCount: Int,
                            chunkSize: Int = NonBlockingFileIO.defaultChunkSize,
                            allocator: ByteBufferAllocator,
                            eventLoop: EventLoop, chunkHandler: @escaping (ByteBuffer) -> EventLoopFuture<Void>) -> EventLoopFuture<Void> {
        precondition(chunkSize > 0, "chunkSize must be > 0 (is \(chunkSize))")
        var remainingReads = 1 + (byteCount / chunkSize)
        let lastReadSize = byteCount % chunkSize

        func _read(remainingReads: Int) -> EventLoopFuture<Void> {
            if remainingReads > 1 || (remainingReads == 1 && lastReadSize > 0) {
                let readSize = remainingReads > 1 ? chunkSize : lastReadSize
                assert(readSize > 0)
                return self.read(fileHandle: fileHandle, byteCount: readSize, allocator: allocator, eventLoop: eventLoop).then { buffer in
                    chunkHandler(buffer).then { () -> EventLoopFuture<Void> in
                        assert(eventLoop.inEventLoop)
                        return _read(remainingReads: remainingReads - 1)
                    }
                }
            } else {
                return eventLoop.newSucceededFuture(result: ())
            }
        }

        return _read(remainingReads: remainingReads)
    }

    /// Read a `FileRegion` in `NonBlockingFileIO`'s private thread pool which is separate from any `EventLoop` thread.
    ///
    /// The returned `ByteBuffer` will not have less than `fileRegion.readableBytes` unless we hit end-of-file in which
    /// case the `ByteBuffer` will contain the bytes available to read.
    ///
    /// - note: Only use this function for small enough `FileRegion`s as it will need to allocate enough memory to hold `fileRegion.readableBytes` bytes.
    /// - note: In most cases you should prefer one of the `readChunked` functions.
    ///
    /// - parameters:
    ///   - fileRegion: The file region to read.
    ///   - allocator: A `ByteBufferAllocator` used to allocate space for the returned `ByteBuffer`.
    ///   - eventLoop: The `EventLoop` to create the returned `EventLoopFuture` from.
    /// - returns: An `EventLoopFuture` which delivers a `ByteBuffer` if the read was successful or a failure on error.
    public func read(fileRegion: FileRegion, allocator: ByteBufferAllocator, eventLoop: EventLoop) -> EventLoopFuture<ByteBuffer> {
        do {
            let readableBytes = fileRegion.readableBytes
            try fileRegion.fileHandle.withUnsafeFileDescriptor { descriptor in
                _ = try Posix.lseek(descriptor: descriptor, offset: off_t(fileRegion.readerIndex), whence: SEEK_SET)
            }
            return self.read(fileHandle: fileRegion.fileHandle,
                             byteCount: readableBytes,
                             allocator: allocator,
                             eventLoop: eventLoop)
        } catch {
            return eventLoop.newFailedFuture(error: error)
        }
    }

    /// Read `byteCount` bytes from `fileHandle` in `NonBlockingFileIO`'s private thread pool which is separate from any `EventLoop` thread.
    ///
    /// The returned `ByteBuffer` will not have less than `byteCount` bytes unless we hit end-of-file in which
    /// case the `ByteBuffer` will contain the bytes available to read.
    ///
    /// - note: Only use this function for small enough `byteCount`s as it will need to allocate enough memory to hold `byteCount` bytes.
    /// - note: `read(fileRegion:allocator:eventLoop:)` should be preferred as it uses `FileRegion` object instead of raw `FileHandle`s.
    ///
    /// - parameters:
    ///   - fileHandle: The `FileHandle` to read.
    ///   - byteCount: The number of bytes to read from `fileHandle`.
    ///   - allocator: A `ByteBufferAllocator` used to allocate space for the returned `ByteBuffer`.
    ///   - eventLoop: The `EventLoop` to create the returned `EventLoopFuture` from.
    /// - returns: An `EventLoopFuture` which delivers a `ByteBuffer` if the read was successful or a failure on error.
    public func read(fileHandle: FileHandle, byteCount: Int, allocator: ByteBufferAllocator, eventLoop: EventLoop) -> EventLoopFuture<ByteBuffer> {
        guard byteCount > 0 else {
            return eventLoop.newSucceededFuture(result: allocator.buffer(capacity: 0))
        }

        var buf = allocator.buffer(capacity: byteCount)
        return self.threadPool.runIfActive(eventLoop: eventLoop) { () -> ByteBuffer in
            var bytesRead = 0
            while bytesRead < byteCount {
                let n = try buf.writeWithUnsafeMutableBytes { ptr in
                    let res = try fileHandle.withUnsafeFileDescriptor { descriptor in
                        try Posix.read(descriptor: descriptor,
                                       pointer: ptr.baseAddress!,
                                       size: byteCount - bytesRead)
                    }
                    switch res {
                    case .processed(let n):
                        assert(n >= 0, "read claims to have read a negative number of bytes \(n)")
                        return n
                    case .wouldBlock:
                        throw Error.descriptorSetToNonBlocking
                    }
                }
                if n == 0 {
                    // EOF
                    break
                } else {
                    bytesRead += n
                }
            }
            return buf
        }
    }

    /// Write `buffer` to `fileHandle` in `NonBlockingFileIO`'s private thread pool which is separate from any `EventLoop` thread.
    ///
    /// - parameters:
    ///   - fileHandle: The `FileHandle` to write to.
    ///   - buffer: The `ByteBuffer` to write.
    ///   - eventLoop: The `EventLoop` to create the returned `EventLoopFuture` from.
    /// - returns: An `EventLoopFuture` which is fulfilled if the write was successful or fails on error.
    public func write(fileHandle: FileHandle,
                      buffer: ByteBuffer,
                      eventLoop: EventLoop) -> EventLoopFuture<()> {
        var byteCount = buffer.readableBytes

        guard byteCount > 0 else {
            return eventLoop.newSucceededFuture(result: ())
        }

        return self.threadPool.runIfActive(eventLoop: eventLoop) {
            var buf = buffer
            while byteCount > 0 {
                let n = try buf.readWithUnsafeReadableBytes { ptr in
                    precondition(ptr.count == byteCount)
                    let res = try fileHandle.withUnsafeFileDescriptor { descriptor in
                        try Posix.write(descriptor: descriptor,
                                        pointer: ptr.baseAddress!,
                                        size: byteCount)
                    }
                    switch res {
                    case .processed(let n):
                        assert(n >= 0, "write claims to have written a negative number of bytes \(n)")
                        return n
                    case .wouldBlock:
                        throw Error.descriptorSetToNonBlocking
                    }
                }

                byteCount -= n
            }
        }
    }

    /// Open the file at `path` on a private thread pool which is separate from any `EventLoop` thread.
    ///
    /// This function will return (a future) of the `FileHandle` associated with the file opened and a `FileRegion`
    /// comprising of the whole file. The caller must close the returned `FileHandle` when it's no longer needed.
    ///
    /// - note: The reason this returns the `FileHandle` and the `FileRegion` is that both the opening of a file as well as the querying of its size are blocking.
    ///
    /// - parameters:
    ///     - path: The path of the file to be opened.
    ///     - eventLoop: The `EventLoop` on which the returned `EventLoopFuture` will fire.
    /// - returns: An `EventLoopFuture` containing the `FileHandle` and the `FileRegion` comprising the whole file.
    public func openFile(path: String, eventLoop: EventLoop) -> EventLoopFuture<(FileHandle, FileRegion)> {
        return self.threadPool.runIfActive(eventLoop: eventLoop) {
            let fh = try FileHandle(path: path)
            do {
                let fr = try FileRegion(fileHandle: fh)
                return (fh, fr)
            } catch {
                _ = try? fh.close()
                throw error
            }
        }
    }

}
