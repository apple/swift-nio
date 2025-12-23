//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import CNIOLinux
import CNIOOpenBSD
import CNIOWindows
import NIOConcurrencyHelpers
import NIOCore

/// ``NonBlockingFileIO`` is a helper that allows you to read files without blocking the calling thread.
///
/// - warning: The `NonBlockingFileIO` API is deprecated, do not use going forward. It's not marked as `deprecated` yet such
///            that users don't get the deprecation warnings affecting their APIs everywhere. For file I/O, please use
///            the `NIOFileSystem` API.
///
/// It is worth noting that `kqueue`, `epoll` or `poll` returning claiming a file is readable does not mean that the
/// data is already available in the kernel's memory. In other words, a `read` from a file can still block even if
/// reported as readable. This behaviour is also documented behaviour:
///
///  - [`poll`](http://pubs.opengroup.org/onlinepubs/009695399/functions/poll.html): "Regular files shall always poll TRUE for reading and writing."
///  - [`epoll`](http://man7.org/linux/man-pages/man7/epoll.7.html): "epoll is simply a faster poll(2), and can be used wherever the latter is used since it shares the same semantics."
///  - [`kqueue`](https://www.freebsd.org/cgi/man.cgi?query=kqueue&sektion=2): "Returns when the file pointer is not at the end of file."
///
/// ``NonBlockingFileIO`` helps to work around this issue by maintaining its own thread pool that is used to read the data
/// from the files into memory. It will then hand the (in-memory) data back which makes it available without the possibility
/// of blocking.
public struct NonBlockingFileIO: Sendable {
    /// The default and recommended size for ``NonBlockingFileIO``'s thread pool.
    @inlinable
    public static var defaultThreadPoolSize: Int { 2 }

    /// The default and recommended chunk size.
    @inlinable
    public static var defaultChunkSize: Int { 128 * 1024 }

    /// ``NonBlockingFileIO`` errors.
    public enum Error: Swift.Error {
        /// ``NonBlockingFileIO`` is meant to be used with file descriptors that are set to the default (blocking) mode.
        /// It doesn't make sense to use it with a file descriptor where `O_NONBLOCK` is set therefore this error is
        /// raised when that was requested.
        case descriptorSetToNonBlocking
    }

    private let threadPool: NIOThreadPool

    /// Initialize a ``NonBlockingFileIO`` which uses the `NIOThreadPool`.
    ///
    /// - Parameters:
    ///   - threadPool: The `NIOThreadPool` that will be used for all the IO.
    public init(threadPool: NIOThreadPool) {
        self.threadPool = threadPool
    }

    /// Read a `FileRegion` in chunks of `chunkSize` bytes on ``NonBlockingFileIO``'s private thread
    /// pool which is separate from any `EventLoop` thread.
    ///
    /// `chunkHandler` will be called on `eventLoop` for every chunk that was read. Assuming `fileRegion.readableBytes` is greater than
    /// zero and there are enough bytes available `chunkHandler` will be called `1 + |_ fileRegion.readableBytes / chunkSize _|`
    /// times, delivering `chunkSize` bytes each time. If less than `fileRegion.readableBytes` bytes can be read from the file,
    /// `chunkHandler` will be called less often with the last invocation possibly being of less than `chunkSize` bytes.
    ///
    /// The allocation and reading of a subsequent chunk will only be attempted when `chunkHandler` succeeds.
    ///
    /// This method will not use the file descriptor's seek pointer which means there is no danger of reading from the
    /// same `FileRegion` in multiple threads.
    ///
    /// - Parameters:
    ///   - fileRegion: The file region to read.
    ///   - chunkSize: The size of the individual chunks to deliver.
    ///   - allocator: A `ByteBufferAllocator` used to allocate space for the chunks.
    ///   - eventLoop: The `EventLoop` to call `chunkHandler` on.
    ///   - chunkHandler: Called for every chunk read. The next chunk will be read upon successful completion of the returned `EventLoopFuture`. If the returned `EventLoopFuture` fails, the overall operation is aborted.
    /// - Returns: An `EventLoopFuture` which is the result of the overall operation. If either the reading of `fileHandle` or `chunkHandler` fails, the `EventLoopFuture` will fail too. If the reading of `fileHandle` as well as `chunkHandler` always succeeded, the `EventLoopFuture` will succeed too.
    @preconcurrency
    public func readChunked(
        fileRegion: FileRegion,
        chunkSize: Int = NonBlockingFileIO.defaultChunkSize,
        allocator: ByteBufferAllocator,
        eventLoop: EventLoop,
        chunkHandler: @escaping @Sendable (ByteBuffer) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Void> {
        let readableBytes = fileRegion.readableBytes
        return self.readChunked(
            fileHandle: fileRegion.fileHandle,
            fromOffset: Int64(fileRegion.readerIndex),
            byteCount: readableBytes,
            chunkSize: chunkSize,
            allocator: allocator,
            eventLoop: eventLoop,
            chunkHandler: chunkHandler
        )
    }

    /// Read `byteCount` bytes in chunks of `chunkSize` bytes from `fileHandle` in ``NonBlockingFileIO``'s private thread
    /// pool which is separate from any `EventLoop` thread.
    ///
    /// `chunkHandler` will be called on `eventLoop` for every chunk that was read. Assuming `byteCount` is greater than
    /// zero and there are enough bytes available `chunkHandler` will be called `1 + |_ byteCount / chunkSize _|`
    /// times, delivering `chunkSize` bytes each time. If less than `byteCount` bytes can be read from `descriptor`,
    /// `chunkHandler` will be called less often with the last invocation possibly being of less than `chunkSize` bytes.
    ///
    /// The allocation and reading of a subsequent chunk will only be attempted when `chunkHandler` succeeds.
    ///
    /// - Note: `readChunked(fileRegion:chunkSize:allocator:eventLoop:chunkHandler:)` should be preferred as it uses
    ///         `FileRegion` object instead of raw `NIOFileHandle`s. In case you do want to use raw `NIOFileHandle`s,
    ///         please consider using `readChunked(fileHandle:fromOffset:chunkSize:allocator:eventLoop:chunkHandler:)`
    ///         because it doesn't use the file descriptor's seek pointer (which may be shared with other file
    ///         descriptors and even across processes.)
    ///
    /// - Parameters:
    ///   - fileHandle: The `NIOFileHandle` to read from.
    ///   - byteCount: The number of bytes to read from `fileHandle`.
    ///   - chunkSize: The size of the individual chunks to deliver.
    ///   - allocator: A `ByteBufferAllocator` used to allocate space for the chunks.
    ///   - eventLoop: The `EventLoop` to call `chunkHandler` on.
    ///   - chunkHandler: Called for every chunk read. The next chunk will be read upon successful completion of the returned `EventLoopFuture`. If the returned `EventLoopFuture` fails, the overall operation is aborted.
    /// - Returns: An `EventLoopFuture` which is the result of the overall operation. If either the reading of `fileHandle` or `chunkHandler` fails, the `EventLoopFuture` will fail too. If the reading of `fileHandle` as well as `chunkHandler` always succeeded, the `EventLoopFuture` will succeed too.
    @preconcurrency
    public func readChunked(
        fileHandle: NIOFileHandle,
        byteCount: Int,
        chunkSize: Int = NonBlockingFileIO.defaultChunkSize,
        allocator: ByteBufferAllocator,
        eventLoop: EventLoop,
        chunkHandler: @escaping @Sendable (ByteBuffer) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Void> {
        self.readChunked0(
            fileHandle: fileHandle,
            fromOffset: nil,
            byteCount: byteCount,
            chunkSize: chunkSize,
            allocator: allocator,
            eventLoop: eventLoop,
            chunkHandler: chunkHandler
        )
    }

    /// Read `byteCount` bytes from offset `fileOffset` in chunks of `chunkSize` bytes from `fileHandle` in ``NonBlockingFileIO``'s private thread
    /// pool which is separate from any `EventLoop` thread.
    ///
    /// `chunkHandler` will be called on `eventLoop` for every chunk that was read. Assuming `byteCount` is greater than
    /// zero and there are enough bytes available `chunkHandler` will be called `1 + |_ byteCount / chunkSize _|`
    /// times, delivering `chunkSize` bytes each time. If less than `byteCount` bytes can be read from `descriptor`,
    /// `chunkHandler` will be called less often with the last invocation possibly being of less than `chunkSize` bytes.
    ///
    /// The allocation and reading of a subsequent chunk will only be attempted when `chunkHandler` succeeds.
    ///
    /// This method will not use the file descriptor's seek pointer which means there is no danger of reading from the
    /// same `NIOFileHandle` in multiple threads.
    ///
    /// - Note: `readChunked(fileRegion:chunkSize:allocator:eventLoop:chunkHandler:)` should be preferred as it uses
    ///         `FileRegion` object instead of raw `NIOFileHandle`s.
    ///
    /// - Parameters:
    ///   - fileHandle: The `NIOFileHandle` to read from.
    ///   - fileOffset: The offset into the file at which the read should begin.
    ///   - byteCount: The number of bytes to read from `fileHandle`.
    ///   - chunkSize: The size of the individual chunks to deliver.
    ///   - allocator: A `ByteBufferAllocator` used to allocate space for the chunks.
    ///   - eventLoop: The `EventLoop` to call `chunkHandler` on.
    ///   - chunkHandler: Called for every chunk read. The next chunk will be read upon successful completion of the returned `EventLoopFuture`. If the returned `EventLoopFuture` fails, the overall operation is aborted.
    /// - Returns: An `EventLoopFuture` which is the result of the overall operation. If either the reading of `fileHandle` or `chunkHandler` fails, the `EventLoopFuture` will fail too. If the reading of `fileHandle` as well as `chunkHandler` always succeeded, the `EventLoopFuture` will succeed too.
    @preconcurrency
    public func readChunked(
        fileHandle: NIOFileHandle,
        fromOffset fileOffset: Int64,
        byteCount: Int,
        chunkSize: Int = NonBlockingFileIO.defaultChunkSize,
        allocator: ByteBufferAllocator,
        eventLoop: EventLoop,
        chunkHandler: @escaping @Sendable (ByteBuffer) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Void> {
        self.readChunked0(
            fileHandle: fileHandle,
            fromOffset: fileOffset,
            byteCount: byteCount,
            chunkSize: chunkSize,
            allocator: allocator,
            eventLoop: eventLoop,
            chunkHandler: chunkHandler
        )
    }

    private typealias ReadChunkHandler = @Sendable (ByteBuffer) -> EventLoopFuture<Void>

    private func readChunked0(
        fileHandle: NIOFileHandle,
        fromOffset: Int64?,
        byteCount: Int,
        chunkSize: Int,
        allocator: ByteBufferAllocator,
        eventLoop: EventLoop,
        chunkHandler: @escaping ReadChunkHandler
    ) -> EventLoopFuture<Void> {
        precondition(chunkSize > 0, "chunkSize must be > 0 (is \(chunkSize))")
        let remainingReads = 1 + (byteCount / chunkSize)
        let lastReadSize = byteCount % chunkSize

        let promise = eventLoop.makePromise(of: Void.self)

        @Sendable
        func _read(remainingReads: Int, bytesReadSoFar: Int64) {
            if remainingReads > 1 || (remainingReads == 1 && lastReadSize > 0) {
                let readSize = remainingReads > 1 ? chunkSize : lastReadSize
                assert(readSize > 0)
                let readFuture = self.read0(
                    fileHandle: fileHandle,
                    fromOffset: fromOffset.map { $0 + bytesReadSoFar },
                    byteCount: readSize,
                    allocator: allocator,
                    eventLoop: eventLoop
                )
                readFuture.whenComplete { (result) in
                    switch result {
                    case .success(let buffer):
                        guard buffer.readableBytes > 0 else {
                            // EOF, call `chunkHandler` one more time.
                            let handlerFuture = chunkHandler(buffer)
                            handlerFuture.cascade(to: promise)
                            return
                        }
                        let bytesRead = Int64(buffer.readableBytes)
                        chunkHandler(buffer).hop(to: eventLoop).whenComplete { result in
                            switch result {
                            case .success(_):
                                eventLoop.assertInEventLoop()
                                _read(
                                    remainingReads: remainingReads - 1,
                                    bytesReadSoFar: bytesReadSoFar + bytesRead
                                )
                            case .failure(let error):
                                promise.fail(error)
                            }
                        }
                    case .failure(let error):
                        promise.fail(error)
                    }
                }
            } else {
                promise.succeed(())
            }
        }
        _read(remainingReads: remainingReads, bytesReadSoFar: 0)

        return promise.futureResult
    }

    /// Read a `FileRegion` in ``NonBlockingFileIO``'s private thread pool which is separate from any `EventLoop` thread.
    ///
    /// The returned `ByteBuffer` will not have less than `fileRegion.readableBytes` unless we hit end-of-file in which
    /// case the `ByteBuffer` will contain the bytes available to read.
    ///
    /// This method will not use the file descriptor's seek pointer which means there is no danger of reading from the
    /// same `FileRegion` in multiple threads.
    ///
    /// - Note: Only use this function for small enough `FileRegion`s as it will need to allocate enough memory to hold `fileRegion.readableBytes` bytes.
    /// - Note: In most cases you should prefer one of the `readChunked` functions.
    ///
    /// - Parameters:
    ///   - fileRegion: The file region to read.
    ///   - allocator: A `ByteBufferAllocator` used to allocate space for the returned `ByteBuffer`.
    ///   - eventLoop: The `EventLoop` to create the returned `EventLoopFuture` from.
    /// - Returns: An `EventLoopFuture` which delivers a `ByteBuffer` if the read was successful or a failure on error.
    public func read(
        fileRegion: FileRegion,
        allocator: ByteBufferAllocator,
        eventLoop: EventLoop
    ) -> EventLoopFuture<ByteBuffer> {
        let readableBytes = fileRegion.readableBytes
        return self.read(
            fileHandle: fileRegion.fileHandle,
            fromOffset: Int64(fileRegion.readerIndex),
            byteCount: readableBytes,
            allocator: allocator,
            eventLoop: eventLoop
        )
    }

    /// Read `byteCount` bytes from `fileHandle` in ``NonBlockingFileIO``'s private thread pool which is separate from any `EventLoop` thread.
    ///
    /// The returned `ByteBuffer` will not have less than `byteCount` bytes unless we hit end-of-file in which
    /// case the `ByteBuffer` will contain the bytes available to read.
    ///
    /// - Note: Only use this function for small enough `byteCount`s as it will need to allocate enough memory to hold `byteCount` bytes.
    /// - Note: ``read(fileRegion:allocator:eventLoop:)`` should be preferred as it uses `FileRegion` object instead of
    ///         raw `NIOFileHandle`s. In case you do want to use raw `NIOFileHandle`s,
    ///         please consider using ``read(fileHandle:fromOffset:byteCount:allocator:eventLoop:)``
    ///         because it doesn't use the file descriptor's seek pointer (which may be shared with other file
    ///         descriptors and even across processes.)
    ///
    /// - Parameters:
    ///   - fileHandle: The `NIOFileHandle` to read.
    ///   - byteCount: The number of bytes to read from `fileHandle`.
    ///   - allocator: A `ByteBufferAllocator` used to allocate space for the returned `ByteBuffer`.
    ///   - eventLoop: The `EventLoop` to create the returned `EventLoopFuture` from.
    /// - Returns: An `EventLoopFuture` which delivers a `ByteBuffer` if the read was successful or a failure on error.
    public func read(
        fileHandle: NIOFileHandle,
        byteCount: Int,
        allocator: ByteBufferAllocator,
        eventLoop: EventLoop
    ) -> EventLoopFuture<ByteBuffer> {
        self.read0(
            fileHandle: fileHandle,
            fromOffset: nil,
            byteCount: byteCount,
            allocator: allocator,
            eventLoop: eventLoop
        )
    }

    /// Read `byteCount` bytes starting at `fileOffset` from `fileHandle` in ``NonBlockingFileIO``'s private thread pool
    /// which is separate from any `EventLoop` thread.
    ///
    /// The returned `ByteBuffer` will not have less than `byteCount` bytes unless we hit end-of-file in which
    /// case the `ByteBuffer` will contain the bytes available to read.
    ///
    /// This method will not use the file descriptor's seek pointer which means there is no danger of reading from the
    /// same `fileHandle` in multiple threads.
    ///
    /// - Note: Only use this function for small enough `byteCount`s as it will need to allocate enough memory to hold `byteCount` bytes.
    /// - Note: ``read(fileRegion:allocator:eventLoop:)`` should be preferred as it uses `FileRegion` object instead of raw `NIOFileHandle`s.
    ///
    /// - Parameters:
    ///   - fileHandle: The `NIOFileHandle` to read.
    ///   - fileOffset: The offset to read from.
    ///   - byteCount: The number of bytes to read from `fileHandle`.
    ///   - allocator: A `ByteBufferAllocator` used to allocate space for the returned `ByteBuffer`.
    ///   - eventLoop: The `EventLoop` to create the returned `EventLoopFuture` from.
    /// - Returns: An `EventLoopFuture` which delivers a `ByteBuffer` if the read was successful or a failure on error.
    public func read(
        fileHandle: NIOFileHandle,
        fromOffset fileOffset: Int64,
        byteCount: Int,
        allocator: ByteBufferAllocator,
        eventLoop: EventLoop
    ) -> EventLoopFuture<ByteBuffer> {
        self.read0(
            fileHandle: fileHandle,
            fromOffset: fileOffset,
            byteCount: byteCount,
            allocator: allocator,
            eventLoop: eventLoop
        )
    }

    private func read0(
        fileHandle: NIOFileHandle,
        fromOffset: Int64?,  // > 2 GB offset is reasonable on 32-bit systems
        byteCount rawByteCount: Int,
        allocator: ByteBufferAllocator,
        eventLoop: EventLoop
    ) -> EventLoopFuture<ByteBuffer> {
        guard rawByteCount > 0 else {
            return eventLoop.makeSucceededFuture(allocator.buffer(capacity: 0))
        }
        let byteCount = rawByteCount < Int32.max ? rawByteCount : size_t(Int32.max)

        return self.threadPool.runIfActive(eventLoop: eventLoop) { () -> ByteBuffer in
            try self.readSync(
                fileHandle: fileHandle,
                fromOffset: fromOffset,
                byteCount: byteCount,
                allocator: allocator
            )
        }
    }

    private func readSync(
        fileHandle: NIOFileHandle,
        fromOffset: Int64?,  // > 2 GB offset is reasonable on 32-bit systems
        byteCount: Int,
        allocator: ByteBufferAllocator
    ) throws -> ByteBuffer {
        var bytesRead = 0
        var buf = allocator.buffer(capacity: byteCount)

        while bytesRead < byteCount {
            let n = try buf.writeWithUnsafeMutableBytes(minimumWritableBytes: byteCount - bytesRead) { ptr -> Int in
                let res = try fileHandle.withUnsafeFileDescriptor { descriptor -> IOResult<ssize_t> in
                    if let offset = fromOffset {
                        #if !os(Windows)
                        return try Posix.pread(
                            descriptor: descriptor,
                            pointer: ptr.baseAddress!,
                            size: byteCount - bytesRead,
                            offset: off_t(offset) + off_t(bytesRead)
                        )
                        #else
                        return try Windows.pread(
                            descriptor: descriptor,
                            pointer: ptr.baseAddress!,
                            size: byteCount - bytesRead,
                            offset: off_t(offset) + off_t(bytesRead)
                        )
                        #endif
                    }

                    return try Posix.read(
                        descriptor: descriptor,
                        pointer: ptr.baseAddress!,
                        size: byteCount - bytesRead
                    )
                }
                switch res {
                case .processed(let n):
                    assert(n >= 0, "read claims to have read a negative number of bytes \(n)")
                    return numericCast(n)  // ssize_t is Int64 on Windows and Int everywhere else.
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

    /// Changes the file size of `fileHandle` to `size`.
    ///
    /// If `size` is smaller than the current file size, the remaining bytes will be truncated and are lost. If `size`
    /// is larger than the current file size, the gap will be filled with zero bytes.
    ///
    /// - Parameters:
    ///   - fileHandle: The `NIOFileHandle` to write to.
    ///   - size: The new file size in bytes to write.
    ///   - eventLoop: The `EventLoop` to create the returned `EventLoopFuture` from.
    /// - Returns: An `EventLoopFuture` which is fulfilled if the write was successful or fails on error.
    public func changeFileSize(
        fileHandle: NIOFileHandle,
        size: Int64,
        eventLoop: EventLoop
    ) -> EventLoopFuture<()> {
        self.threadPool.runIfActive(eventLoop: eventLoop) {
            try fileHandle.withUnsafeFileDescriptor { descriptor -> Void in
                try Posix.ftruncate(descriptor: descriptor, size: off_t(size))
            }
        }
    }

    /// Returns the length of the file in bytes associated with `fileHandle`.
    ///
    /// - Parameters:
    ///   - fileHandle: The `NIOFileHandle` to read from.
    ///   - eventLoop: The `EventLoop` to create the returned `EventLoopFuture` from.
    /// - Returns: An `EventLoopFuture` which is fulfilled with the length of the file in bytes if the write was successful or fails on error.
    public func readFileSize(
        fileHandle: NIOFileHandle,
        eventLoop: EventLoop
    ) -> EventLoopFuture<Int64> {
        self.threadPool.runIfActive(eventLoop: eventLoop) {
            try fileHandle.withUnsafeFileDescriptor { descriptor in
                let curr = try Posix.lseek(descriptor: descriptor, offset: 0, whence: SEEK_CUR)
                let eof = try Posix.lseek(descriptor: descriptor, offset: 0, whence: SEEK_END)
                try Posix.lseek(descriptor: descriptor, offset: curr, whence: SEEK_SET)
                return Int64(eof)
            }
        }
    }

    /// Write `buffer` to `fileHandle` in ``NonBlockingFileIO``'s private thread pool which is separate from any `EventLoop` thread.
    ///
    /// - Parameters:
    ///   - fileHandle: The `NIOFileHandle` to write to.
    ///   - buffer: The `ByteBuffer` to write.
    ///   - eventLoop: The `EventLoop` to create the returned `EventLoopFuture` from.
    /// - Returns: An `EventLoopFuture` which is fulfilled if the write was successful or fails on error.
    public func write(
        fileHandle: NIOFileHandle,
        buffer: ByteBuffer,
        eventLoop: EventLoop
    ) -> EventLoopFuture<()> {
        self.write0(fileHandle: fileHandle, toOffset: nil, buffer: buffer, eventLoop: eventLoop)
    }

    /// Write `buffer` starting from `toOffset` to `fileHandle` in ``NonBlockingFileIO``'s private thread pool which is separate from any `EventLoop` thread.
    ///
    /// - Parameters:
    ///   - fileHandle: The `NIOFileHandle` to write to.
    ///   - toOffset: The file offset to write to.
    ///   - buffer: The `ByteBuffer` to write.
    ///   - eventLoop: The `EventLoop` to create the returned `EventLoopFuture` from.
    /// - Returns: An `EventLoopFuture` which is fulfilled if the write was successful or fails on error.
    public func write(
        fileHandle: NIOFileHandle,
        toOffset: Int64,
        buffer: ByteBuffer,
        eventLoop: EventLoop
    ) -> EventLoopFuture<()> {
        self.write0(fileHandle: fileHandle, toOffset: toOffset, buffer: buffer, eventLoop: eventLoop)
    }

    private func write0(
        fileHandle: NIOFileHandle,
        toOffset: Int64?,
        buffer: ByteBuffer,
        eventLoop: EventLoop
    ) -> EventLoopFuture<()> {
        let byteCount = buffer.readableBytes

        guard byteCount > 0 else {
            return eventLoop.makeSucceededFuture(())
        }

        return self.threadPool.runIfActive(eventLoop: eventLoop) {
            try self.writeSync(fileHandle: fileHandle, byteCount: byteCount, toOffset: toOffset, buffer: buffer)
        }
    }

    private func writeSync(
        fileHandle: NIOFileHandle,
        byteCount: Int,
        toOffset: Int64?,
        buffer: ByteBuffer
    ) throws {
        var buf = buffer

        var offsetAccumulator: Int = 0
        repeat {
            let n = try buf.readWithUnsafeReadableBytes { ptr in
                precondition(ptr.count == byteCount - offsetAccumulator)
                let res: IOResult<ssize_t> = try fileHandle.withUnsafeFileDescriptor { descriptor in
                    if let toOffset = toOffset {
                        #if os(Windows)
                        return try Windows.pwrite(
                            descriptor: descriptor,
                            pointer: ptr.baseAddress!,
                            size: byteCount - offsetAccumulator,
                            offset: off_t(toOffset + Int64(offsetAccumulator))
                        )
                        #else
                        return try Posix.pwrite(
                            descriptor: descriptor,
                            pointer: ptr.baseAddress!,
                            size: byteCount - offsetAccumulator,
                            offset: off_t(toOffset + Int64(offsetAccumulator))
                        )
                        #endif
                    } else {
                        let result = try Posix.write(
                            descriptor: descriptor,
                            pointer: ptr.baseAddress!,
                            size: byteCount - offsetAccumulator
                        )
                        #if os(Windows)
                        return result.map { ssize_t($0) }
                        #else
                        return result
                        #endif
                    }
                }
                switch res {
                case .processed(let n):
                    assert(n >= 0, "write claims to have written a negative number of bytes \(n)")
                    return numericCast(n)
                case .wouldBlock:
                    throw Error.descriptorSetToNonBlocking
                }
            }
            offsetAccumulator += n
        } while offsetAccumulator < byteCount
    }

    /// Open the file at `path` for reading on a private thread pool which is separate from any `EventLoop` thread.
    ///
    /// This function will return (a future) of the `NIOFileHandle` associated with the file opened and a `FileRegion`
    /// comprising of the whole file. The caller must close the returned `NIOFileHandle` when it's no longer needed.
    ///
    /// - Note: The reason this returns the `NIOFileHandle` and the `FileRegion` is that both the opening of a file as well as the querying of its size are blocking.
    ///
    /// - Parameters:
    ///   - path: The path of the file to be opened for reading.
    ///   - eventLoop: The `EventLoop` on which the returned `EventLoopFuture` will fire.
    /// - Returns: An `EventLoopFuture` containing the `NIOFileHandle` and the `FileRegion` comprising the whole file.
    @available(
        *,
        deprecated,
        message:
            "Avoid using NIOFileHandle. The type is difficult to hold correctly, use NIOFileSystem as a replacement API."
    )
    public func openFile(path: String, eventLoop: EventLoop) -> EventLoopFuture<(NIOFileHandle, FileRegion)> {
        self.openFile(_deprecatedPath: path, eventLoop: eventLoop)
    }

    /// Open the file at `path` for reading on a private thread pool which is separate from any `EventLoop` thread.
    ///
    /// This function will return (a future) of the `NIOFileHandle` associated with the file opened and a `FileRegion`
    /// comprising of the whole file. The caller must close the returned `NIOFileHandle` when it's no longer needed.
    ///
    /// - Note: The reason this returns the `NIOFileHandle` and the `FileRegion` is that both the opening of a file as well as the querying of its size are blocking.
    ///
    /// - Parameters:
    ///   - path: The path of the file to be opened for reading.
    ///   - eventLoop: The `EventLoop` on which the returned `EventLoopFuture` will fire.
    /// - Returns: An `EventLoopFuture` containing the `NIOFileHandle` and the `FileRegion` comprising the whole file.
    public func openFile(
        _deprecatedPath path: String,
        eventLoop: EventLoop
    ) -> EventLoopFuture<(NIOFileHandle, FileRegion)> {
        self.threadPool.runIfActive(eventLoop: eventLoop) {
            let fh = try NIOFileHandle(_deprecatedPath: path)
            do {
                let fr = try FileRegion(fileHandle: fh)
                return (fh, fr)
            } catch {
                _ = try? fh.close()
                throw error
            }
        }
    }

    /// Open the file at `path` with specified access mode and POSIX flags on a private thread pool which is separate from any `EventLoop` thread.
    ///
    /// This function will return (a future) of the `NIOFileHandle` associated with the file opened.
    /// The caller must close the returned `NIOFileHandle` when it's no longer needed.
    ///
    /// - Parameters:
    ///   - path: The path of the file to be opened for writing.
    ///   - mode: File access mode.
    ///   - flags: Additional POSIX flags.
    ///   - eventLoop: The `EventLoop` on which the returned `EventLoopFuture` will fire.
    /// - Returns: An `EventLoopFuture` containing the `NIOFileHandle`.
    @available(
        *,
        deprecated,
        message:
            "Avoid using NonBlockingFileIO. The type is difficult to hold correctly, use NIOFileSystem as a replacement API."
    )
    public func openFile(
        path: String,
        mode: NIOFileHandle.Mode,
        flags: NIOFileHandle.Flags = .default,
        eventLoop: EventLoop
    ) -> EventLoopFuture<NIOFileHandle> {
        self.openFile(_deprecatedPath: path, mode: mode, flags: flags, eventLoop: eventLoop)
    }

    /// Open the file at `path` with specified access mode and POSIX flags on a private thread pool which is separate from any `EventLoop` thread.
    ///
    /// This function will return (a future) of the `NIOFileHandle` associated with the file opened.
    /// The caller must close the returned `NIOFileHandle` when it's no longer needed.
    ///
    /// - Parameters:
    ///   - path: The path of the file to be opened for writing.
    ///   - mode: File access mode.
    ///   - flags: Additional POSIX flags.
    ///   - eventLoop: The `EventLoop` on which the returned `EventLoopFuture` will fire.
    /// - Returns: An `EventLoopFuture` containing the `NIOFileHandle`.
    public func openFile(
        _deprecatedPath path: String,
        mode: NIOFileHandle.Mode,
        flags: NIOFileHandle.Flags = .default,
        eventLoop: EventLoop
    ) -> EventLoopFuture<NIOFileHandle> {
        self.threadPool.runIfActive(eventLoop: eventLoop) {
            try NIOFileHandle(_deprecatedPath: path, mode: mode, flags: flags)
        }
    }

    #if !os(Windows)
    /// Returns information about a file at `path` on a private thread pool which is separate from any `EventLoop` thread.
    ///
    /// - Note: If `path` is a symlink, information about the link, not the file it points to.
    ///
    /// - Parameters:
    ///   - path: The path of the file to get information about.
    ///   - eventLoop: The `EventLoop` on which the returned `EventLoopFuture` will fire.
    /// - Returns: An `EventLoopFuture` containing file information.
    public func lstat(path: String, eventLoop: EventLoop) -> EventLoopFuture<stat> {
        self.threadPool.runIfActive(eventLoop: eventLoop) {
            var s = stat()
            try Posix.lstat(pathname: path, outStat: &s)
            return s
        }
    }

    /// Creates a symbolic link to a  `destination` file  at `path` on a private thread pool which is separate from any `EventLoop` thread.
    ///
    /// - Parameters:
    ///   - path: The path of the link.
    ///   - destination: Target path where this link will point to.
    ///   - eventLoop: The `EventLoop` on which the returned `EventLoopFuture` will fire.
    /// - Returns: An `EventLoopFuture` which is fulfilled if the rename was successful or fails on error.
    public func symlink(path: String, to destination: String, eventLoop: EventLoop) -> EventLoopFuture<Void> {
        self.threadPool.runIfActive(eventLoop: eventLoop) {
            try Posix.symlink(pathname: path, destination: destination)
        }
    }

    /// Returns target of the symbolic link at `path` on a private thread pool which is separate from any `EventLoop` thread.
    ///
    /// - Parameters:
    ///   - path: The path of the link to read.
    ///   - eventLoop: The `EventLoop` on which the returned `EventLoopFuture` will fire.
    /// - Returns: An `EventLoopFuture` containing link target.
    public func readlink(path: String, eventLoop: EventLoop) -> EventLoopFuture<String> {
        self.threadPool.runIfActive(eventLoop: eventLoop) {
            let maxLength = Int(PATH_MAX)
            let pointer = UnsafeMutableBufferPointer<CChar>.allocate(capacity: maxLength)
            defer {
                pointer.deallocate()
            }
            let length = try Posix.readlink(pathname: path, outPath: pointer.baseAddress!, outPathSize: maxLength)
            return String(decoding: UnsafeRawBufferPointer(pointer).prefix(length), as: UTF8.self)
        }
    }

    /// Removes symbolic link at `path` on a private thread pool which is separate from any `EventLoop` thread.
    ///
    /// - Parameters:
    ///   - path: The path of the link to remove.
    ///   - eventLoop: The `EventLoop` on which the returned `EventLoopFuture` will fire.
    /// - Returns: An `EventLoopFuture` which is fulfilled if the rename was successful or fails on error.
    public func unlink(path: String, eventLoop: EventLoop) -> EventLoopFuture<Void> {
        self.threadPool.runIfActive(eventLoop: eventLoop) {
            try Posix.unlink(pathname: path)
        }
    }

    private func createDirectory0(_ path: String, mode: NIOPOSIXFileMode) throws {
        let pathView = path.utf8
        if pathView.isEmpty {
            return
        }

        // Fail fast if not a directory or file exists
        do {
            var s = stat()
            try Posix.stat(pathname: path, outStat: &s)
            if (S_IFMT & s.st_mode) == S_IFDIR {
                return
            }
            throw IOError(errnoCode: ENOTDIR, reason: "Not a directory")
        } catch let error as IOError where error.errnoCode == ENOENT {
            // if directory does not exist we can proceed with creating it
        }

        // Slow path, check that all intermediate directories exist recursively

        // Trim any trailing path separators
        var index = pathView.index(before: pathView.endIndex)
        let pathSeparator = UInt8(ascii: "/")
        while index != pathView.startIndex && pathView[index] == pathSeparator {
            index = pathView.index(before: index)
        }

        // Find first non-trailing path separator if it exists
        while index != pathView.startIndex && pathView[index] != pathSeparator {
            index = pathView.index(before: index)
        }

        // If non-trailing path separator is found, create parent directory
        if index > pathView.startIndex {
            try self.createDirectory0(String(Substring(pathView.prefix(upTo: index))), mode: mode)
        }

        do {
            try Posix.mkdir(pathname: path, mode: mode)
        } catch {
            // If user tries to create a path like `/some/path/.` it may fail, as path will be created
            // by the recursive call. Checks if directory exists and re-throw the error if it does not
            do {
                var s = stat()
                try Posix.lstat(pathname: path, outStat: &s)
                if (S_IFMT & s.st_mode) == S_IFDIR {
                    return
                }
            } catch {
                // fallthrough
            }
            throw error
        }
    }

    /// Creates directory at `path` on a private thread pool which is separate from any `EventLoop` thread.
    ///
    /// - Parameters:
    ///   - path: The path of the directory to be created.
    ///   - createIntermediates: Whether intermediate directories should be created.
    ///   - mode: POSIX file mode.
    ///   - eventLoop: The `EventLoop` on which the returned `EventLoopFuture` will fire.
    /// - Returns: An `EventLoopFuture` which is fulfilled if the rename was successful or fails on error.
    public func createDirectory(
        path: String,
        withIntermediateDirectories createIntermediates: Bool = false,
        mode: NIOPOSIXFileMode,
        eventLoop: EventLoop
    ) -> EventLoopFuture<Void> {
        self.threadPool.runIfActive(eventLoop: eventLoop) {
            if createIntermediates {
                #if canImport(Darwin)
                try Posix.mkpath_np(pathname: path, mode: mode)
                #else
                try self.createDirectory0(path, mode: mode)
                #endif
            } else {
                try Posix.mkdir(pathname: path, mode: mode)
            }
        }
    }

    /// List contents of the directory at `path` on a private thread pool which is separate from any `EventLoop` thread.
    ///
    /// - Parameters:
    ///   - path: The path of the directory to list the content of.
    ///   - eventLoop: The `EventLoop` on which the returned `EventLoopFuture` will fire.
    /// - Returns: An `EventLoopFuture` containing the directory entries.
    public func listDirectory(path: String, eventLoop: EventLoop) -> EventLoopFuture<[NIODirectoryEntry]> {
        self.threadPool.runIfActive(eventLoop: eventLoop) {
            let dir = try Posix.opendir(pathname: path)
            var entries: [NIODirectoryEntry] = []
            do {
                while let entry = try Posix.readdir(dir: dir) {
                    let name = withUnsafeBytes(of: entry.pointee.d_name) { pointer -> String in
                        let ptr = pointer.baseAddress!.assumingMemoryBound(to: CChar.self)
                        return String(cString: ptr)
                    }
                    #if os(OpenBSD)
                    let ino = entry.pointee.d_fileno
                    #else
                    let ino = entry.pointee.d_ino
                    #endif
                    entries.append(
                        NIODirectoryEntry(ino: UInt64(ino), type: entry.pointee.d_type, name: name)
                    )
                }
                try? Posix.closedir(dir: dir)
            } catch {
                try? Posix.closedir(dir: dir)
                throw error
            }
            return entries
        }
    }

    /// Renames the file at `path` to `newName` on a private thread pool which is separate from any `EventLoop` thread.
    ///
    /// - Parameters:
    ///   - path: The path of the file to be renamed.
    ///   - newName: New file name.
    ///   - eventLoop: The `EventLoop` on which the returned `EventLoopFuture` will fire.
    /// - Returns: An `EventLoopFuture` which is fulfilled if the rename was successful or fails on error.
    public func rename(path: String, newName: String, eventLoop: EventLoop) -> EventLoopFuture<Void> {
        self.threadPool.runIfActive(eventLoop: eventLoop) {
            try Posix.rename(pathname: path, newName: newName)
        }
    }

    /// Removes the file at `path` on a private thread pool which is separate from any `EventLoop` thread.
    ///
    /// - Parameters:
    ///   - path: The path of the file to be removed.
    ///   - eventLoop: The `EventLoop` on which the returned `EventLoopFuture` will fire.
    /// - Returns: An `EventLoopFuture` which is fulfilled if the remove was successful or fails on error.
    public func remove(path: String, eventLoop: EventLoop) -> EventLoopFuture<Void> {
        self.threadPool.runIfActive(eventLoop: eventLoop) {
            try Posix.remove(pathname: path)
        }
    }
    #endif
}

#if !os(Windows)
/// A `NIODirectoryEntry` represents a single directory entry.
public struct NIODirectoryEntry: Hashable, Sendable {
    // File number of entry
    public var ino: UInt64
    // File type
    public var type: UInt8
    // File name
    public var name: String

    public init(ino: UInt64, type: UInt8, name: String) {
        self.ino = ino
        self.type = type
        self.name = name
    }
}
#endif

extension NonBlockingFileIO {
    /// Read a `FileRegion` in ``NonBlockingFileIO``'s private thread pool.
    ///
    /// The returned `ByteBuffer` will not have less than the minimum of `fileRegion.readableBytes` and `UInt32.max` unless we hit
    /// end-of-file in which case the `ByteBuffer` will contain the bytes available to read.
    ///
    /// This method will not use the file descriptor's seek pointer which means there is no danger of reading from the
    /// same `FileRegion` in multiple threads.
    ///
    /// - Note: Only use this function for small enough `FileRegion`s as it will need to allocate enough memory to hold `fileRegion.readableBytes` bytes.
    /// - Note: In most cases you should prefer one of the `readChunked` functions.
    ///
    /// - Parameters:
    ///   - fileRegion: The file region to read.
    ///   - allocator: A `ByteBufferAllocator` used to allocate space for the returned `ByteBuffer`.
    /// - Returns: ByteBuffer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func read(fileRegion: FileRegion, allocator: ByteBufferAllocator) async throws -> ByteBuffer {
        let readableBytes = fileRegion.readableBytes
        return try await self.read(
            fileHandle: fileRegion.fileHandle,
            fromOffset: Int64(fileRegion.readerIndex),
            byteCount: readableBytes,
            allocator: allocator
        )
    }

    /// Read `byteCount` bytes from `fileHandle` in ``NonBlockingFileIO``'s private thread pool.
    ///
    /// The returned `ByteBuffer` will not have less than `byteCount` bytes unless we hit end-of-file in which
    /// case the `ByteBuffer` will contain the bytes available to read.
    ///
    /// - Note: Only use this function for small enough `byteCount`s as it will need to allocate enough memory to hold `byteCount` bytes.
    /// - Note: ``read(fileRegion:allocator:eventLoop:)`` should be preferred as it uses `FileRegion` object instead of
    ///         raw `NIOFileHandle`s. In case you do want to use raw `NIOFileHandle`s,
    ///         please consider using ``read(fileHandle:fromOffset:byteCount:allocator:eventLoop:)``
    ///         because it doesn't use the file descriptor's seek pointer (which may be shared with other file
    ///         descriptors and even across processes.)
    ///
    /// - Parameters:
    ///   - fileHandle: The `NIOFileHandle` to read.
    ///   - byteCount: The number of bytes to read from `fileHandle`.
    ///   - allocator: A `ByteBufferAllocator` used to allocate space for the returned `ByteBuffer`.
    /// - Returns: ByteBuffer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func read(
        fileHandle: NIOFileHandle,
        byteCount: Int,
        allocator: ByteBufferAllocator
    ) async throws -> ByteBuffer {
        try await self.read0(
            fileHandle: fileHandle,
            fromOffset: nil,
            byteCount: byteCount,
            allocator: allocator
        )
    }

    /// Read `byteCount` bytes starting at `fileOffset` from `fileHandle` in ``NonBlockingFileIO``'s private thread pool
    ///.
    ///
    /// The returned `ByteBuffer` will not have less than `byteCount` bytes unless we hit end-of-file in which
    /// case the `ByteBuffer` will contain the bytes available to read.
    ///
    /// This method will not use the file descriptor's seek pointer which means there is no danger of reading from the
    /// same `fileHandle` in multiple threads.
    ///
    /// - Note: Only use this function for small enough `byteCount`s as it will need to allocate enough memory to hold `byteCount` bytes.
    /// - Note: ``read(fileRegion:allocator:eventLoop:)`` should be preferred as it uses `FileRegion` object instead of raw `NIOFileHandle`s.
    ///
    /// - Parameters:
    ///   - fileHandle: The `NIOFileHandle` to read.
    ///   - fileOffset: The offset to read from.
    ///   - byteCount: The number of bytes to read from `fileHandle`.
    ///   - allocator: A `ByteBufferAllocator` used to allocate space for the returned `ByteBuffer`.
    /// - Returns: ByteBuffer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func read(
        fileHandle: NIOFileHandle,
        fromOffset fileOffset: Int64,
        byteCount: Int,
        allocator: ByteBufferAllocator
    ) async throws -> ByteBuffer {
        try await self.read0(
            fileHandle: fileHandle,
            fromOffset: fileOffset,
            byteCount: byteCount,
            allocator: allocator
        )
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    private func read0(
        fileHandle: NIOFileHandle,
        fromOffset: Int64?,  // > 2 GB offset is reasonable on 32-bit systems
        byteCount rawByteCount: Int,
        allocator: ByteBufferAllocator
    ) async throws -> ByteBuffer {
        guard rawByteCount > 0 else {
            return allocator.buffer(capacity: 0)
        }
        let byteCount = rawByteCount < Int32.max ? rawByteCount : size_t(Int32.max)

        return try await self.threadPool.runIfActive { () -> ByteBuffer in
            try self.readSync(
                fileHandle: fileHandle,
                fromOffset: fromOffset,
                byteCount: byteCount,
                allocator: allocator
            )
        }
    }

    /// Changes the file size of `fileHandle` to `size`.
    ///
    /// If `size` is smaller than the current file size, the remaining bytes will be truncated and are lost. If `size`
    /// is larger than the current file size, the gap will be filled with zero bytes.
    ///
    /// - Parameters:
    ///   - fileHandle: The `NIOFileHandle` to write to.
    ///   - size: The new file size in bytes to write.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func changeFileSize(
        fileHandle: NIOFileHandle,
        size: Int64
    ) async throws {
        try await self.threadPool.runIfActive {
            try fileHandle.withUnsafeFileDescriptor { descriptor -> Void in
                try Posix.ftruncate(descriptor: descriptor, size: off_t(size))
            }
        }
    }

    /// Returns the length of the file associated with `fileHandle`.
    ///
    /// - Parameters:
    ///   - fileHandle: The `NIOFileHandle` to read from.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func readFileSize(fileHandle: NIOFileHandle) async throws -> Int64 {
        try await self.threadPool.runIfActive {
            try fileHandle.withUnsafeFileDescriptor { descriptor in
                let curr = try Posix.lseek(descriptor: descriptor, offset: 0, whence: SEEK_CUR)
                let eof = try Posix.lseek(descriptor: descriptor, offset: 0, whence: SEEK_END)
                try Posix.lseek(descriptor: descriptor, offset: curr, whence: SEEK_SET)
                return Int64(eof)
            }
        }
    }

    /// Write `buffer` to `fileHandle` in ``NonBlockingFileIO``'s private thread pool.
    ///
    /// - Parameters:
    ///   - fileHandle: The `NIOFileHandle` to write to.
    ///   - buffer: The `ByteBuffer` to write.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func write(
        fileHandle: NIOFileHandle,
        buffer: ByteBuffer
    ) async throws {
        try await self.write0(fileHandle: fileHandle, toOffset: nil, buffer: buffer)
    }

    /// Write `buffer` starting from `toOffset` to `fileHandle` in ``NonBlockingFileIO``'s private thread pool.
    ///
    /// - Parameters:
    ///   - fileHandle: The `NIOFileHandle` to write to.
    ///   - toOffset: The file offset to write to.
    ///   - buffer: The `ByteBuffer` to write.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func write(
        fileHandle: NIOFileHandle,
        toOffset: Int64,
        buffer: ByteBuffer
    ) async throws {
        try await self.write0(fileHandle: fileHandle, toOffset: toOffset, buffer: buffer)
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    private func write0(
        fileHandle: NIOFileHandle,
        toOffset: Int64?,
        buffer: ByteBuffer
    ) async throws {
        let byteCount = buffer.readableBytes

        guard byteCount > 0 else {
            return
        }

        return try await self.threadPool.runIfActive {
            try self.writeSync(fileHandle: fileHandle, byteCount: byteCount, toOffset: toOffset, buffer: buffer)
        }
    }

    /// Open file at `path` and query its size on a private thread pool, run an operation given
    /// the resulting file region and then close the file handle.
    ///
    /// The will return the result of the operation.
    ///
    /// - Note: This function opens a file and queries it size which are both blocking operations
    ///
    /// - Parameters:
    ///   - path: The path of the file to be opened for reading.
    ///   - body: operation to run with file handle and region
    /// - Returns: return value of operation
    @available(
        *,
        deprecated,
        message:
            "Avoid using NonBlockingFileIO. The API is difficult to hold correctly, use NIOFileSystem as a replacement API."
    )
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func withFileRegion<Result>(
        path: String,
        _ body: (_ fileRegion: FileRegion) async throws -> Result
    ) async throws -> Result {
        try await self.withFileRegion(_deprecatedPath: path, body)
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func withFileRegion<Result>(
        _deprecatedPath path: String,
        _ body: (_ fileRegion: FileRegion) async throws -> Result
    ) async throws -> Result {
        let fileRegion = try await self.threadPool.runIfActive {
            let fh = try NIOFileHandle(_deprecatedPath: path)
            do {
                return try FileRegion(fileHandle: fh)
            } catch {
                _ = try? fh.close()
                throw error
            }
        }
        let result: Result
        do {
            result = try await body(fileRegion)
        } catch {
            try fileRegion.fileHandle.close()
            throw error
        }
        try fileRegion.fileHandle.close()
        return result
    }

    /// Open file at `path` on a private thread pool, run an operation given the file handle and then close the file handle.
    ///
    /// This function will return the result of the operation.
    ///
    /// - Parameters:
    ///   - path: The path of the file to be opened for writing.
    ///   - mode: File access mode.
    ///   - flags: Additional POSIX flags.
    ///   - body: operation to run with the file handle
    /// - Returns: return value of operation
    @available(
        *,
        deprecated,
        message:
            "Avoid using NonBlockingFileIO. The API is difficult to hold correctly, use NIOFileSystem as a replacement API."
    )
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func withFileHandle<Result>(
        path: String,
        mode: NIOFileHandle.Mode,
        flags: NIOFileHandle.Flags = .default,
        _ body: (NIOFileHandle) async throws -> Result
    ) async throws -> Result {
        try await self.withFileHandle(_deprecatedPath: path, mode: mode, flags: flags, body)
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func withFileHandle<Result>(
        _deprecatedPath path: String,
        mode: NIOFileHandle.Mode,
        flags: NIOFileHandle.Flags = .default,
        _ body: (NIOFileHandle) async throws -> Result
    ) async throws -> Result {
        let fileHandle = try await self.threadPool.runIfActive {
            try NIOFileHandle(_deprecatedPath: path, mode: mode, flags: flags)
        }
        let result: Result
        do {
            result = try await body(fileHandle)
        } catch {
            try fileHandle.close()
            throw error
        }
        try fileHandle.close()
        return result
    }

    #if !os(Windows)

    /// Returns information about a file at `path` on a private thread pool.
    ///
    /// - Note: If `path` is a symlink, information about the link, not the file it points to.
    ///
    /// - Parameters:
    ///   - path: The path of the file to get information about.
    /// - Returns: file information.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func lstat(path: String) async throws -> stat {
        try await self.threadPool.runIfActive {
            var s = stat()
            try Posix.lstat(pathname: path, outStat: &s)
            return s
        }
    }

    /// Creates a symbolic link to a  `destination` file  at `path` on a private thread pool.
    ///
    /// - Parameters:
    ///   - path: The path of the link.
    ///   - destination: Target path where this link will point to.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func symlink(path: String, to destination: String) async throws {
        try await self.threadPool.runIfActive {
            try Posix.symlink(pathname: path, destination: destination)
        }
    }

    /// Returns target of the symbolic link at `path` on a private thread pool.
    ///
    /// - Parameters:
    ///   - path: The path of the link to read.
    /// - Returns: link target.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func readlink(path: String) async throws -> String {
        try await self.threadPool.runIfActive {
            let maxLength = Int(PATH_MAX)
            let pointer = UnsafeMutableBufferPointer<CChar>.allocate(capacity: maxLength)
            defer {
                pointer.deallocate()
            }
            let length = try Posix.readlink(pathname: path, outPath: pointer.baseAddress!, outPathSize: maxLength)
            return String(decoding: UnsafeRawBufferPointer(pointer).prefix(length), as: UTF8.self)
        }
    }

    /// Removes symbolic link at `path` on a private thread pool which is separate from any `EventLoop` thread.
    ///
    /// - Parameters:
    ///   - path: The path of the link to remove.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func unlink(path: String) async throws {
        try await self.threadPool.runIfActive {
            try Posix.unlink(pathname: path)
        }
    }

    /// Creates directory at `path` on a private thread pool.
    ///
    /// - Parameters:
    ///   - path: The path of the directory to be created.
    ///   - createIntermediates: Whether intermediate directories should be created.
    ///   - mode: POSIX file mode.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func createDirectory(
        path: String,
        withIntermediateDirectories createIntermediates: Bool = false,
        mode: NIOPOSIXFileMode
    ) async throws {
        try await self.threadPool.runIfActive {
            if createIntermediates {
                #if canImport(Darwin)
                try Posix.mkpath_np(pathname: path, mode: mode)
                #else
                try self.createDirectory0(path, mode: mode)
                #endif
            } else {
                try Posix.mkdir(pathname: path, mode: mode)
            }
        }
    }

    /// List contents of the directory at `path` on a private thread pool.
    ///
    /// - Parameters:
    ///   - path: The path of the directory to list the content of.
    /// - Returns: The directory entries.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func listDirectory(path: String) async throws -> [NIODirectoryEntry] {
        try await self.threadPool.runIfActive {
            let dir = try Posix.opendir(pathname: path)
            var entries: [NIODirectoryEntry] = []
            do {
                while let entry = try Posix.readdir(dir: dir) {
                    let name = withUnsafeBytes(of: entry.pointee.d_name) { pointer -> String in
                        let ptr = pointer.baseAddress!.assumingMemoryBound(to: CChar.self)
                        return String(cString: ptr)
                    }
                    #if os(OpenBSD)
                    let ino = entry.pointee.d_fileno
                    #else
                    let ino = entry.pointee.d_ino
                    #endif
                    entries.append(
                        NIODirectoryEntry(ino: UInt64(ino), type: entry.pointee.d_type, name: name)
                    )
                }
                try? Posix.closedir(dir: dir)
            } catch {
                try? Posix.closedir(dir: dir)
                throw error
            }
            return entries
        }
    }

    /// Renames the file at `path` to `newName` on a private thread pool.
    ///
    /// - Parameters:
    ///   - path: The path of the file to be renamed.
    ///   - newName: New file name.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func rename(path: String, newName: String) async throws {
        try await self.threadPool.runIfActive {
            try Posix.rename(pathname: path, newName: newName)
        }
    }

    /// Removes the file at `path` on a private thread pool.
    ///
    /// - Parameters:
    ///   - path: The path of the file to be removed.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func remove(path: String) async throws {
        try await self.threadPool.runIfActive {
            try Posix.remove(pathname: path)
        }
    }
    #endif
}
