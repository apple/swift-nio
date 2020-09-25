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

    private let threadPool: NIOThreadPool

    /// Initialize a `NonBlockingFileIO` which uses the `NIOThreadPool`.
    ///
    /// - parameters:
    ///   - threadPool: The `NIOThreadPool` that will be used for all the IO.
    public init(threadPool: NIOThreadPool) {
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
    /// This method will not use the file descriptor's seek pointer which means there is no danger of reading from the
    /// same `FileRegion` in multiple threads.
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
        let readableBytes = fileRegion.readableBytes
        return self.readChunked(fileHandle: fileRegion.fileHandle,
                                fromOffset: Int64(fileRegion.readerIndex),
                                byteCount: readableBytes,
                                chunkSize: chunkSize,
                                allocator: allocator,
                                eventLoop: eventLoop,
                                chunkHandler: chunkHandler)
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
    /// - note: `readChunked(fileRegion:chunkSize:allocator:eventLoop:chunkHandler:)` should be preferred as it uses
    ///         `FileRegion` object instead of raw `NIOFileHandle`s. In case you do want to use raw `NIOFileHandle`s,
    ///         please consider using `readChunked(fileHandle:fromOffset:chunkSize:allocator:eventLoop:chunkHandler:)`
    ///         because it doesn't use the file descriptor's seek pointer (which may be shared with other file
    ///         descriptors and even across processes.)
    ///
    /// - parameters:
    ///   - fileHandle: The `NIOFileHandle` to read from.
    ///   - byteCount: The number of bytes to read from `fileHandle`.
    ///   - chunkSize: The size of the individual chunks to deliver.
    ///   - allocator: A `ByteBufferAllocator` used to allocate space for the chunks.
    ///   - eventLoop: The `EventLoop` to call `chunkHandler` on.
    ///   - chunkHandler: Called for every chunk read. The next chunk will be read upon successful completion of the returned `EventLoopFuture`. If the returned `EventLoopFuture` fails, the overall operation is aborted.
    /// - returns: An `EventLoopFuture` which is the result of the overall operation. If either the reading of `fileHandle` or `chunkHandler` fails, the `EventLoopFuture` will fail too. If the reading of `fileHandle` as well as `chunkHandler` always succeeded, the `EventLoopFuture` will succeed too.
    public func readChunked(fileHandle: NIOFileHandle,
                            byteCount: Int,
                            chunkSize: Int = NonBlockingFileIO.defaultChunkSize,
                            allocator: ByteBufferAllocator,
                            eventLoop: EventLoop, chunkHandler: @escaping (ByteBuffer) -> EventLoopFuture<Void>) -> EventLoopFuture<Void> {
        return self.readChunked0(fileHandle: fileHandle,
                                fromOffset: nil,
                                byteCount: byteCount,
                                chunkSize: chunkSize,
                                allocator: allocator,
                                eventLoop: eventLoop,
                                chunkHandler: chunkHandler)
    }

    /// Read `byteCount` bytes from offset `fileOffset` in chunks of `chunkSize` bytes from `fileHandle` in `NonBlockingFileIO`'s private thread
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
    /// - note: `readChunked(fileRegion:chunkSize:allocator:eventLoop:chunkHandler:)` should be preferred as it uses
    ///         `FileRegion` object instead of raw `NIOFileHandle`s.
    ///
    /// - parameters:
    ///   - fileHandle: The `NIOFileHandle` to read from.
    ///   - byteCount: The number of bytes to read from `fileHandle`.
    ///   - chunkSize: The size of the individual chunks to deliver.
    ///   - allocator: A `ByteBufferAllocator` used to allocate space for the chunks.
    ///   - eventLoop: The `EventLoop` to call `chunkHandler` on.
    ///   - chunkHandler: Called for every chunk read. The next chunk will be read upon successful completion of the returned `EventLoopFuture`. If the returned `EventLoopFuture` fails, the overall operation is aborted.
    /// - returns: An `EventLoopFuture` which is the result of the overall operation. If either the reading of `fileHandle` or `chunkHandler` fails, the `EventLoopFuture` will fail too. If the reading of `fileHandle` as well as `chunkHandler` always succeeded, the `EventLoopFuture` will succeed too.
    public func readChunked(fileHandle: NIOFileHandle,
                            fromOffset fileOffset: Int64,
                            byteCount: Int,
                            chunkSize: Int = NonBlockingFileIO.defaultChunkSize,
                            allocator: ByteBufferAllocator,
                            eventLoop: EventLoop,
                            chunkHandler: @escaping (ByteBuffer) -> EventLoopFuture<Void>) -> EventLoopFuture<Void> {
        return self.readChunked0(fileHandle: fileHandle,
                                 fromOffset: fileOffset,
                                 byteCount: byteCount,
                                 chunkSize: chunkSize,
                                 allocator: allocator,
                                 eventLoop: eventLoop,
                                 chunkHandler: chunkHandler)
    }

    private func readChunked0(fileHandle: NIOFileHandle,
                              fromOffset: Int64?,
                              byteCount: Int,
                              chunkSize: Int,
                              allocator: ByteBufferAllocator,
                              eventLoop: EventLoop, chunkHandler: @escaping (ByteBuffer) -> EventLoopFuture<Void>) -> EventLoopFuture<Void> {
        precondition(chunkSize > 0, "chunkSize must be > 0 (is \(chunkSize))")
        let remainingReads = 1 + (byteCount / chunkSize)
        let lastReadSize = byteCount % chunkSize
      
        let promise = eventLoop.makePromise(of: Void.self)

        func _read(remainingReads: Int, bytesReadSoFar: Int64) {
            if remainingReads > 1 || (remainingReads == 1 && lastReadSize > 0) {
                let readSize = remainingReads > 1 ? chunkSize : lastReadSize
                assert(readSize > 0)
                let readFuture = self.read0(fileHandle: fileHandle,
                                            fromOffset: fromOffset.map { $0 + bytesReadSoFar },
                                            byteCount: readSize,
                                            allocator: allocator,
                                            eventLoop: eventLoop)
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
                        chunkHandler(buffer).whenComplete { result in
                            switch result {
                            case .success(_):
                                eventLoop.assertInEventLoop()
                                _read(remainingReads: remainingReads - 1,
                                      bytesReadSoFar: bytesReadSoFar + bytesRead)
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

    /// Read a `FileRegion` in `NonBlockingFileIO`'s private thread pool which is separate from any `EventLoop` thread.
    ///
    /// The returned `ByteBuffer` will not have less than `fileRegion.readableBytes` unless we hit end-of-file in which
    /// case the `ByteBuffer` will contain the bytes available to read.
    ///
    /// This method will not use the file descriptor's seek pointer which means there is no danger of reading from the
    /// same `FileRegion` in multiple threads.
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
        let readableBytes = fileRegion.readableBytes
        return self.read(fileHandle: fileRegion.fileHandle,
                         fromOffset: Int64(fileRegion.readerIndex),
                         byteCount: readableBytes,
                         allocator: allocator,
                         eventLoop: eventLoop)
    }

    /// Read `byteCount` bytes from `fileHandle` in `NonBlockingFileIO`'s private thread pool which is separate from any `EventLoop` thread.
    ///
    /// The returned `ByteBuffer` will not have less than `byteCount` bytes unless we hit end-of-file in which
    /// case the `ByteBuffer` will contain the bytes available to read.
    ///
    /// - note: Only use this function for small enough `byteCount`s as it will need to allocate enough memory to hold `byteCount` bytes.
    /// - note: `read(fileRegion:allocator:eventLoop:)` should be preferred as it uses `FileRegion` object instead of
    ///         raw `NIOFileHandle`s. In case you do want to use raw `NIOFileHandle`s,
    ///         please consider using `read(fileHandle:fromOffset:byteCount:allocator:eventLoop:)`
    ///         because it doesn't use the file descriptor's seek pointer (which may be shared with other file
    ///         descriptors and even across processes.)
    ///
    /// - parameters:
    ///   - fileHandle: The `NIOFileHandle` to read.
    ///   - byteCount: The number of bytes to read from `fileHandle`.
    ///   - allocator: A `ByteBufferAllocator` used to allocate space for the returned `ByteBuffer`.
    ///   - eventLoop: The `EventLoop` to create the returned `EventLoopFuture` from.
    /// - returns: An `EventLoopFuture` which delivers a `ByteBuffer` if the read was successful or a failure on error.
    public func read(fileHandle: NIOFileHandle,
                     byteCount: Int,
                     allocator: ByteBufferAllocator,
                     eventLoop: EventLoop) -> EventLoopFuture<ByteBuffer> {
        return self.read0(fileHandle: fileHandle,
                         fromOffset: nil,
                         byteCount: byteCount,
                         allocator: allocator,
                         eventLoop: eventLoop)
    }

    /// Read `byteCount` bytes starting at `fileOffset` from `fileHandle` in `NonBlockingFileIO`'s private thread pool
    /// which is separate from any `EventLoop` thread.
    ///
    /// The returned `ByteBuffer` will not have less than `byteCount` bytes unless we hit end-of-file in which
    /// case the `ByteBuffer` will contain the bytes available to read.
    ///
    /// This method will not use the file descriptor's seek pointer which means there is no danger of reading from the
    /// same `fileHandle` in multiple threads.
    ///
    /// - note: Only use this function for small enough `byteCount`s as it will need to allocate enough memory to hold `byteCount` bytes.
    /// - note: `read(fileRegion:allocator:eventLoop:)` should be preferred as it uses `FileRegion` object instead of raw `NIOFileHandle`s.
    ///
    /// - parameters:
    ///   - fileHandle: The `NIOFileHandle` to read.
    ///   - fileOffset: The offset to read from.
    ///   - byteCount: The number of bytes to read from `fileHandle`.
    ///   - allocator: A `ByteBufferAllocator` used to allocate space for the returned `ByteBuffer`.
    ///   - eventLoop: The `EventLoop` to create the returned `EventLoopFuture` from.
    /// - returns: An `EventLoopFuture` which delivers a `ByteBuffer` if the read was successful or a failure on error.
    public func read(fileHandle: NIOFileHandle,
                     fromOffset fileOffset: Int64,
                     byteCount: Int,
                     allocator: ByteBufferAllocator,
                     eventLoop: EventLoop) -> EventLoopFuture<ByteBuffer> {
        return self.read0(fileHandle: fileHandle,
                          fromOffset: fileOffset,
                          byteCount: byteCount,
                          allocator: allocator,
                          eventLoop: eventLoop)
    }

    private func read0(fileHandle: NIOFileHandle,
                       fromOffset: Int64?, // > 2 GB offset is reasonable on 32-bit systems
                       byteCount: Int,
                       allocator: ByteBufferAllocator,
                       eventLoop: EventLoop) -> EventLoopFuture<ByteBuffer> {
        guard byteCount > 0 else {
            return eventLoop.makeSucceededFuture(allocator.buffer(capacity: 0))
        }

        var buf = allocator.buffer(capacity: byteCount)
        return self.threadPool.runIfActive(eventLoop: eventLoop) { () -> ByteBuffer in
            var bytesRead = 0
            while bytesRead < byteCount {
                let n = try buf.writeWithUnsafeMutableBytes(minimumWritableBytes: byteCount - bytesRead) { ptr in
                    let res = try fileHandle.withUnsafeFileDescriptor { descriptor -> IOResult<ssize_t> in
                        if let offset = fromOffset {
                            return try Posix.pread(descriptor: descriptor,
                                                   pointer: ptr.baseAddress!,
                                                   size: byteCount - bytesRead,
                                                   offset: off_t(offset) + off_t(bytesRead))
                        } else {
                            return try Posix.read(descriptor: descriptor,
                                                  pointer: ptr.baseAddress!,
                                                  size: byteCount - bytesRead)
                        }
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

    /// Changes the file size of `fileHandle` to `size`.
    ///
    /// If `size` is smaller than the current file size, the remaining bytes will be truncated and are lost. If `size`
    /// is larger than the current file size, the gap will be filled with zero bytes.
    ///
    /// - parameters:
    ///   - fileHandle: The `NIOFileHandle` to write to.
    ///   - size: The new file size in bytes to write.
    ///   - eventLoop: The `EventLoop` to create the returned `EventLoopFuture` from.
    /// - returns: An `EventLoopFuture` which is fulfilled if the write was successful or fails on error.
    public func changeFileSize(fileHandle: NIOFileHandle,
                               size: Int64,
                               eventLoop: EventLoop) -> EventLoopFuture<()> {
        return self.threadPool.runIfActive(eventLoop: eventLoop) {
            try fileHandle.withUnsafeFileDescriptor { descriptor -> Void in
                try Posix.ftruncate(descriptor: descriptor, size: off_t(size))
            }
        }
    }

    /// Returns the length of the file associated with `fileHandle`.
    ///
    /// - parameters:
    ///   - fileHandle: The `NIOFileHandle` to read from.
    ///   - eventLoop: The `EventLoop` to create the returned `EventLoopFuture` from.
    /// - returns: An `EventLoopFuture` which is fulfilled if the write was successful or fails on error.
    public func readFileSize(fileHandle: NIOFileHandle,
                             eventLoop: EventLoop) -> EventLoopFuture<Int64> {
        return self.threadPool.runIfActive(eventLoop: eventLoop) {
            return try fileHandle.withUnsafeFileDescriptor { descriptor in
                let curr = try Posix.lseek(descriptor: descriptor, offset: 0, whence: SEEK_CUR)
                let eof = try Posix.lseek(descriptor: descriptor, offset: 0, whence: SEEK_END)
                try Posix.lseek(descriptor: descriptor, offset: curr, whence: SEEK_SET)
                return Int64(eof)
            }
        }
    }

    /// Write `buffer` to `fileHandle` in `NonBlockingFileIO`'s private thread pool which is separate from any `EventLoop` thread.
    ///
    /// - parameters:
    ///   - fileHandle: The `NIOFileHandle` to write to.
    ///   - buffer: The `ByteBuffer` to write.
    ///   - eventLoop: The `EventLoop` to create the returned `EventLoopFuture` from.
    /// - returns: An `EventLoopFuture` which is fulfilled if the write was successful or fails on error.
    public func write(fileHandle: NIOFileHandle,
                      buffer: ByteBuffer,
                      eventLoop: EventLoop) -> EventLoopFuture<()> {
        return self.write0(fileHandle: fileHandle, toOffset: nil, buffer: buffer, eventLoop: eventLoop)
    }

    /// Write `buffer` starting from `toOffset` to `fileHandle` in `NonBlockingFileIO`'s private thread pool which is separate from any `EventLoop` thread.
    ///
    /// - parameters:
    ///   - fileHandle: The `NIOFileHandle` to write to.
    ///   - toOffset: The file offset to write to.
    ///   - buffer: The `ByteBuffer` to write.
    ///   - eventLoop: The `EventLoop` to create the returned `EventLoopFuture` from.
    /// - returns: An `EventLoopFuture` which is fulfilled if the write was successful or fails on error.
    public func write(fileHandle: NIOFileHandle,
                      toOffset: Int64,
                      buffer: ByteBuffer,
                      eventLoop: EventLoop) -> EventLoopFuture<()> {
        return self.write0(fileHandle: fileHandle, toOffset: toOffset, buffer: buffer, eventLoop: eventLoop)
    }

    private func write0(fileHandle: NIOFileHandle,
                        toOffset: Int64?,
                        buffer: ByteBuffer,
                        eventLoop: EventLoop) -> EventLoopFuture<()> {
        let byteCount = buffer.readableBytes

        guard byteCount > 0 else {
            return eventLoop.makeSucceededFuture(())
        }

        return self.threadPool.runIfActive(eventLoop: eventLoop) {
            var buf = buffer

            var offsetAccumulator: Int = 0
            repeat {
                let n = try buf.readWithUnsafeReadableBytes { ptr in
                    precondition(ptr.count == byteCount - offsetAccumulator)
                    let res: IOResult<ssize_t> = try fileHandle.withUnsafeFileDescriptor { descriptor in
                        if let toOffset = toOffset {
                            return try Posix.pwrite(descriptor: descriptor,
                                                    pointer: ptr.baseAddress!,
                                                    size: byteCount - offsetAccumulator,
                                                    offset: off_t(toOffset + Int64(offsetAccumulator)))
                        } else {
                            return try Posix.write(descriptor: descriptor,
                                                   pointer: ptr.baseAddress!,
                                                   size: byteCount - offsetAccumulator)
                        }
                    }
                    switch res {
                    case .processed(let n):
                        assert(n >= 0, "write claims to have written a negative number of bytes \(n)")
                        return n
                    case .wouldBlock:
                        throw Error.descriptorSetToNonBlocking
                    }
                }
                offsetAccumulator += n
            } while offsetAccumulator < byteCount
        }
    }

    /// Open the file at `path` for reading on a private thread pool which is separate from any `EventLoop` thread.
    ///
    /// This function will return (a future) of the `NIOFileHandle` associated with the file opened and a `FileRegion`
    /// comprising of the whole file. The caller must close the returned `NIOFileHandle` when it's no longer needed.
    ///
    /// - note: The reason this returns the `NIOFileHandle` and the `FileRegion` is that both the opening of a file as well as the querying of its size are blocking.
    ///
    /// - parameters:
    ///     - path: The path of the file to be opened for reading.
    ///     - eventLoop: The `EventLoop` on which the returned `EventLoopFuture` will fire.
    /// - returns: An `EventLoopFuture` containing the `NIOFileHandle` and the `FileRegion` comprising the whole file.
    public func openFile(path: String, eventLoop: EventLoop) -> EventLoopFuture<(NIOFileHandle, FileRegion)> {
        return self.threadPool.runIfActive(eventLoop: eventLoop) {
            let fh = try NIOFileHandle(path: path)
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
    /// - parameters:
    ///     - path: The path of the file to be opened for writing.
    ///     - mode: File access mode.
    ///     - flags: Additional POSIX flags.
    ///     - eventLoop: The `EventLoop` on which the returned `EventLoopFuture` will fire.
    /// - returns: An `EventLoopFuture` containing the `NIOFileHandle`.
    public func openFile(path: String, mode: NIOFileHandle.Mode, flags: NIOFileHandle.Flags = .default, eventLoop: EventLoop) -> EventLoopFuture<NIOFileHandle> {
        return self.threadPool.runIfActive(eventLoop: eventLoop) {
            return try NIOFileHandle(path: path, mode: mode, flags: flags)
        }
    }

}
