//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import SystemPackage

/// A handle for a file system object.
///
/// There is a hierarchy of file handle protocols which allow for different functionality. All
/// file handle protocols refine the base ``FileHandleProtocol`` protocol.
///
/// ```
///                                      ┌────────────────────┐
///                                      │ FileHandleProtocol │
///                                      │     [Protocol]     │
///                                      └────────────────────┘
///                                                ▲
///                 ┌──────────────────────────────┼────────────────────────────────┐
///                 │                              │                                │
/// ┌────────────────────────────┐   ┌────────────────────────────┐  ┌─────────────────────────────┐
/// │ ReadableFileHandleProtocol │   │ WritableFileHandleProtocol │  │ DirectoryFileHandleProtocol │
/// │          [Protocol]        │   │         [Protocol]         │  │          [Protocol]         │
/// └────────────────────────────┘   └────────────────────────────┘  └─────────────────────────────┘
/// ```
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public protocol FileHandleProtocol {
    /// Returns information about the file.
    ///
    /// Information is typically gathered by calling `fstat(2)` on the file.
    ///
    /// - Returns: Information about the open file.
    func info() async throws -> FileInfo

    /// Replaces the permissions set on the file.
    ///
    /// Permissions are typically set using `fchmod(2)`.
    ///
    /// - Parameters:
    ///   - permissions: The permissions to set on the file.
    func replacePermissions(_ permissions: FilePermissions) async throws

    /// Adds permissions to the existing permissions set for the file.
    ///
    /// This is equivalent to retrieving the permissions, merging them with the provided
    /// permissions and then replacing the permissions on the file.
    ///
    /// - Parameters:
    ///   - permissions: The permissions to add to the file.
    /// - Returns: The updated permissions.
    @discardableResult
    func addPermissions(_ permissions: FilePermissions) async throws -> FilePermissions

    /// Remove permissions from the existing permissions set for the file.
    ///
    /// This is equivalent to retrieving the permissions, subtracting any of the provided
    /// permissions and then replacing the permissions on the file.
    ///
    /// - Parameters:
    ///   - permissions: The permissions to remove from the file.
    /// - Returns: The updated permissions.
    @discardableResult
    func removePermissions(_ permissions: FilePermissions) async throws -> FilePermissions

    /// Returns an array containing the names of all extended attributes set on the file.
    ///
    /// Attributes names are typically fetched using `flistxattr(2)`.
    func attributeNames() async throws -> [String]

    /// Returns the value for the named attribute if it exists; `nil` otherwise.
    ///
    /// Attribute values are typically fetched using `fgetxattr(2)`.
    ///
    /// - Parameters:
    ///   - name: The name of the attribute.
    /// - Returns: The bytes of the value set for the attribute. If no value is set an empty array
    ///     is returned.
    func valueForAttribute(_ name: String) async throws -> [UInt8]

    /// Replaces the value for the named attribute, creating it if it didn't already exist.
    ///
    /// Attribute values are typically replaced using `fsetxattr(2)`.
    ///
    /// - Parameters:
    ///   - bytes: The bytes to set as the value for the attribute.
    ///   - name: The name of the attribute.
    func updateValueForAttribute(
        _ bytes: some (Sendable & RandomAccessCollection<UInt8>),
        attribute name: String
    ) async throws

    /// Removes the value for the named attribute if it exists.
    ///
    /// Attribute values are typically removed using `fremovexattr(2)`.
    ///
    /// - Parameter name: The name of the attribute to remove.
    func removeValueForAttribute(_ name: String) async throws

    /// Synchronize modified data and metadata to a permanent storage device.
    ///
    /// This is typically achieved using `fsync(2)`.
    func synchronize() async throws

    /// Runs the provided callback with the file descriptor for this handle.
    ///
    /// This function should be used with caution: the `FileDescriptor` must not be escaped from
    /// the closure nor should it be closed. Where possible make use of the methods defined
    /// on ``FileHandleProtocol`` instead; this function is intended as an escape hatch.
    ///
    /// Note that `execute` is not run if the handle has already been closed.
    ///
    /// - Parameter execute: A closure to run.
    /// - Returns: The result of the closure.
    func withUnsafeDescriptor<R: Sendable>(
        _ execute: @Sendable @escaping (FileDescriptor) throws -> R
    ) async throws -> R

    /// Detaches and returns the file descriptor from the handle.
    ///
    /// After detaching the file descriptor the handle is rendered invalid. All methods will throw
    /// an appropriate error if called. Detaching the descriptor yields ownerships to the caller.
    ///
    /// - Returns: The detached `FileDescriptor`
    func detachUnsafeFileDescriptor() throws -> FileDescriptor

    /// Closes the file handle.
    ///
    /// It is important to close a handle once it has been finished with to avoid leaking
    /// resources. Prefer using APIs which provided scoped access to a file handle which
    /// manage lifecycles on your behalf. Note that if the handle has been detached via
    /// ``detachUnsafeFileDescriptor()`` then it is not necessary to close the handle.
    ///
    /// After closing the handle calls to other functions will throw an appropriate error.
    func close() async throws

    /// Sets the file's last access and last data modification times to the given values.
    ///
    /// If **either** time is `nil`, the current value will not be changed.
    /// If **both** times are `nil`, then both times will be set to the current time.
    ///
    /// > Important: Times are only considered valid if their nanoseconds components are one of the following:
    /// > - `UTIME_NOW` (you can use ``FileInfo/Timespec/now`` to get a Timespec set to this value),
    /// > - `UTIME_OMIT` (you can use ``FileInfo/Timespec/omit`` to get a Timespec set to this value),
    /// > - Greater than zero and no larger than 1000 million: if outside of this range, the value will be clamped to the closest valid value.
    /// > The seconds component must also be positive: if it's not, zero will be used as the value instead.
    ///
    /// - Parameters:
    ///   - lastAccess: The new value of the file's last access time, as time elapsed since the Epoch.
    ///   - lastDataModification: The new value of the file's last data modification time, as time elapsed since the Epoch.
    ///
    /// - Throws: If there's an error updating the times. If this happens, the original values won't be modified.
    func setTimes(
        lastAccess: FileInfo.Timespec?,
        lastDataModification: FileInfo.Timespec?
    ) async throws
}

// MARK: - Readable

/// A handle for reading data from an open file.
///
/// ``ReadableFileHandleProtocol`` refines ``FileHandleProtocol`` to add requirements for reading data from a file.
///
/// There are two requirements for implementing this protocol:
/// 1. ``readChunk(fromAbsoluteOffset:length:)``, and
/// 2. ``readChunks(chunkLength:)
///
/// A number of overloads are provided which provide sensible defaults.
///
/// Conformance to ``ReadableFileHandleProtocol`` also provides
/// ``readToEnd(fromAbsoluteOffset:maximumSizeAllowed:)`` (and various overloads with sensible
/// defaults) for reading the contents of a file into memory.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public protocol ReadableFileHandleProtocol: FileHandleProtocol {
    /// Returns a slice of bytes read from the file.
    ///
    /// The length of the slice to read indicates the largest size in bytes that the returned slice
    /// may be. The slice may be shorter than the given `length` if there are fewer bytes from the
    /// `offset` to the end of the file.
    ///
    /// - Parameters:
    ///   - offset: The absolute offset into the file to read from.
    ///   - length: The maximum number of bytes to read as a ``ByteCount``.
    /// - Returns: The bytes read from the file.
    func readChunk(fromAbsoluteOffset offset: Int64, length: ByteCount) async throws -> ByteBuffer

    /// Returns an asynchronous sequence of chunks read from the file.
    ///
    /// - Parameters:
    ///   - range: The absolute offsets into the file to read.
    ///   - chunkLength: The maximum length of the chunk to read as a ``ByteCount``.
    /// - Returns: A sequence of chunks read from the file.
    func readChunks(in range: Range<Int64>, chunkLength: ByteCount) -> FileChunks
}

// MARK: - Read chunks with default chunk length

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension ReadableFileHandleProtocol {
    /// Returns an asynchronous sequence of chunks read from the file.
    ///
    /// - Parameters:
    ///   - range: A range of offsets in the file to read.
    ///   - chunkLength: The length of chunks to read, defaults to 128 KiB.
    /// - SeeAlso: ``ReadableFileHandleProtocol/readChunks(in:chunkLength:)-2dz6``
    /// - Returns: An `AsyncSequence` of chunks read from the file.
    public func readChunks(
        in range: ClosedRange<Int64>,
        chunkLength: ByteCount = .kibibytes(128)
    ) -> FileChunks {
        self.readChunks(in: Range(range), chunkLength: chunkLength)
    }

    /// Returns an asynchronous sequence of chunks read from the file.
    ///
    /// - Parameters:
    ///   - range: A range of offsets in the file to read.
    ///   - chunkLength: The length of chunks to read, defaults to 128 KiB.
    /// - SeeAlso: ``ReadableFileHandleProtocol/readChunks(in:chunkLength:)-2dz6``
    /// - Returns: An `AsyncSequence` of chunks read from the file.
    public func readChunks(
        in range: Range<Int64>,
        chunkLength: ByteCount = .kibibytes(128)
    ) -> FileChunks {
        self.readChunks(in: range, chunkLength: chunkLength)
    }

    /// Returns an asynchronous sequence of chunks read from the file.
    ///
    /// - Parameters:
    ///   - range: A range of offsets in the file to read.
    ///   - chunkLength: The length of chunks to read, defaults to 128 KiB.
    /// - SeeAlso: ``ReadableFileHandleProtocol/readChunks(in:chunkLength:)-2dz6``.
    /// - Returns: An `AsyncSequence` of chunks read from the file.
    public func readChunks(
        in range: PartialRangeFrom<Int64>,
        chunkLength: ByteCount = .kibibytes(128)
    ) -> FileChunks {
        let newRange = range.lowerBound..<Int64.max
        return self.readChunks(in: newRange, chunkLength: chunkLength)
    }

    /// Returns an asynchronous sequence of chunks read from the file.
    ///
    /// - Parameters:
    ///   - range: A range of offsets in the file to read.
    ///   - chunkLength: The length of chunks to read, defaults to 128 KiB.
    /// - SeeAlso: ``ReadableFileHandleProtocol/readChunks(in:chunkLength:)-2dz6``.
    /// - Returns: An `AsyncSequence` of chunks read from the file.
    public func readChunks(
        in range: PartialRangeThrough<Int64>,
        chunkLength: ByteCount = .kibibytes(128)
    ) -> FileChunks {
        let newRange = 0...range.upperBound
        return self.readChunks(in: newRange, chunkLength: chunkLength)
    }

    /// Returns an asynchronous sequence of chunks read from the file.
    ///
    /// - Parameters:
    ///   - range: A range of offsets in the file to read.
    ///   - chunkLength: The length of chunks to read, defaults to 128 KiB.
    /// - SeeAlso: ``ReadableFileHandleProtocol/readChunks(in:chunkLength:)-2dz6``.
    /// - Returns: An `AsyncSequence` of chunks read from the file.
    public func readChunks(
        in range: PartialRangeUpTo<Int64>,
        chunkLength: ByteCount = .kibibytes(128)
    ) -> FileChunks {
        let newRange = 0..<range.upperBound
        return self.readChunks(in: newRange, chunkLength: chunkLength)
    }

    /// Returns an asynchronous sequence of chunks read from the file.
    ///
    /// - Parameters:
    ///   - range: A range of offsets in the file to read.
    ///   - chunkLength: The length of chunks to read, defaults to 128 KiB.
    /// - SeeAlso: ``ReadableFileHandleProtocol/readChunks(in:chunkLength:)-2dz6``.
    /// - Returns: An `AsyncSequence` of chunks read from the file.
    public func readChunks(
        in range: UnboundedRange,
        chunkLength: ByteCount = .kibibytes(128)
    ) -> FileChunks {
        self.readChunks(in: 0..<Int64.max, chunkLength: chunkLength)
    }

    /// Returns an asynchronous sequence of chunks read from the file.
    ///
    /// - Parameters:
    ///   - chunkLength: The length of chunks to read, defaults to 128 KiB.
    /// - SeeAlso: ``ReadableFileHandleProtocol/readChunks(in:chunkLength:)-2dz6``.
    /// - Returns: An `AsyncSequence` of chunks read from the file.
    public func readChunks(
        chunkLength: ByteCount = .kibibytes(128)
    ) -> FileChunks {
        self.readChunks(in: ..., chunkLength: chunkLength)
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension ReadableFileHandleProtocol {
    /// Returns the contents of a file by loading it into memory.
    ///
    /// - Important: This method checks whether the file is seekable or not (i.e., whether it's a socket,
    /// pipe or FIFO), and will throw ``FileSystemError/Code-swift.struct/unsupported`` if
    /// an offset other than zero is passed.
    ///
    /// - Parameters:
    ///   - offset: The absolute offset into the file to read from. Defaults to zero.
    ///   - maximumSizeAllowed: The maximum size of file to read, as a ``ByteCount``.
    /// - Returns: The bytes read from the file.
    /// - Throws: ``FileSystemError`` with code ``FileSystemError/Code-swift.struct/resourceExhausted``
    /// if `maximumSizeAllowed` is more than can be written to `ByteBuffer`. Or if there are more bytes to read than
    /// `maximumBytesAllowed`.
    public func readToEnd(
        fromAbsoluteOffset offset: Int64 = 0,
        maximumSizeAllowed: ByteCount
    ) async throws -> ByteBuffer {
        let maximumSizeAllowed = maximumSizeAllowed == .unlimited ? .byteBufferCapacity : maximumSizeAllowed
        let info = try await self.info()
        let fileSize = Int64(info.size)
        let readSize = max(Int(fileSize - offset), 0)

        if maximumSizeAllowed > .byteBufferCapacity {
            throw FileSystemError(
                code: .resourceExhausted,
                message: """
                    The maximum size allowed (\(maximumSizeAllowed)) is more than the maximum \
                    amount of bytes that can be written to ByteBuffer \
                    (\(ByteCount.byteBufferCapacity)). You can read the file in smaller chunks by \
                    calling readChunks().
                    """,
                cause: nil,
                location: .here()
            )
        }

        if readSize > maximumSizeAllowed.bytes {
            throw FileSystemError(
                code: .resourceExhausted,
                message: """
                    There are more bytes to read (\(readSize)) than the maximum size allowed \
                    (\(maximumSizeAllowed)). Read the file in chunks or increase the maximum size \
                    allowed.
                    """,
                cause: nil,
                location: .here()
            )
        }

        let isSeekable = !(info.type == .fifo || info.type == .socket)
        if isSeekable {
            // Limit the size of single shot reads. If the system is busy then avoid slowing down other
            // work by blocking an I/O executor thread while doing a large read. The limit is somewhat
            // arbitrary.
            let singleShotReadLimit = 64 * 1024 * 1024

            // If the file size isn't 0 but the read size is, then it means that
            // we are intending to read an empty fragment: we can just return
            // fast and skip any reads.
            // If the file size is 0, we can't conclude anything about the size
            // of the file, as `stat` will return 0 for unbounded files.
            // If this happens, just read in chunks to make sure the whole file
            // is read (up to `maximumSizeAllowed` bytes).
            var forceChunkedRead = false
            if fileSize > 0 {
                if readSize == 0 {
                    return ByteBuffer()
                }
            } else {
                forceChunkedRead = true
            }

            if !forceChunkedRead, readSize <= singleShotReadLimit {
                return try await self.readChunk(
                    fromAbsoluteOffset: offset,
                    length: .bytes(Int64(readSize))
                )
            } else {
                var accumulator = ByteBuffer()
                accumulator.reserveCapacity(readSize)

                for try await chunk in self.readChunks(in: offset..., chunkLength: .mebibytes(8)) {
                    accumulator.writeImmutableBuffer(chunk)
                    if accumulator.readableBytes > maximumSizeAllowed.bytes {
                        throw FileSystemError(
                            code: .resourceExhausted,
                            message: """
                                There are more bytes to read than the maximum size allowed \
                                (\(maximumSizeAllowed)). Read the file in chunks or increase the maximum size \
                                allowed.
                                """,
                            cause: nil,
                            location: .here()
                        )
                    }
                }

                return accumulator
            }
        } else {
            guard offset == 0 else {
                throw FileSystemError(
                    code: .unsupported,
                    message: "File is unseekable.",
                    cause: nil,
                    location: .here()
                )
            }
            var accumulator = ByteBuffer()
            accumulator.reserveCapacity(readSize)

            for try await chunk in self.readChunks(in: ..., chunkLength: .mebibytes(8)) {
                accumulator.writeImmutableBuffer(chunk)
                if accumulator.readableBytes > maximumSizeAllowed.bytes {
                    throw FileSystemError(
                        code: .resourceExhausted,
                        message: """
                            There are more bytes to read than the maximum size allowed \
                            (\(maximumSizeAllowed)). Read the file in chunks or increase the maximum size \
                            allowed.
                            """,
                        cause: nil,
                        location: .here()
                    )
                }
            }

            return accumulator
        }
    }
}

// MARK: - Writable

/// A file handle suitable for writing.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public protocol WritableFileHandleProtocol: FileHandleProtocol {
    /// Write the given bytes to the open file.
    ///
    /// - Important: This method checks whether the file is seekable or not (i.e., whether it's a socket,
    /// pipe or FIFO), and will throw ``FileSystemError/Code-swift.struct/unsupported``
    /// if an offset other than zero is passed.
    ///
    /// - Parameters:
    ///   - bytes: The bytes to write.
    ///   - offset: The absolute offset into the file to write the bytes.
    /// - Returns: The number of bytes written.
    /// - Throws: ``FileSystemError/Code-swift.struct/unsupported`` if file is
    /// unseekable and `offset` is not 0.
    @discardableResult
    func write(
        contentsOf bytes: some (Sequence<UInt8> & Sendable),
        toAbsoluteOffset offset: Int64
    ) async throws -> Int64

    /// Resizes a file to the given size.
    ///
    /// - Parameters:
    ///   - size: The number of bytes to resize the file to as a ``ByteCount``.
    func resize(
        to size: ByteCount
    ) async throws

    /// Closes the file handle.
    ///
    /// It is important to close a handle once it has been finished with to avoid leaking
    /// resources. Prefer using APIs which provided scoped access to a file handle which
    /// manage lifecycles on your behalf. Note that if the handle has been detached via
    /// ``FileHandleProtocol/detachUnsafeFileDescriptor()`` then it is not necessary to close
    /// the handle.
    ///
    /// After closing the handle calls to other functions will throw an appropriate error.
    ///
    /// - Parameters:
    ///   - makeChangesVisible: Whether the changes made to the file will be made visibile. This
    ///       parameter is ignored unless ``OpenOptions/NewFile/transactionalCreation`` was
    ///       set to `true`. When `makeChangesVisible` is `true`, the file will be created on the
    ///       filesystem with the expected name, otherwise no file will be created or the original
    ///       file won't be modified (if one existed).
    func close(makeChangesVisible: Bool) async throws
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension WritableFileHandleProtocol {
    /// Write the readable bytes of the `ByteBuffer` to the open file.
    ///
    /// - Important: This method checks whether the file is seekable or not (i.e., whether it's a socket,
    /// pipe or FIFO), and will throw ``FileSystemError/Code-swift.struct/unsupported``
    /// if an offset other than zero is passed.
    ///
    /// - Parameters:
    ///   - buffer: The bytes to write.
    ///   - offset: The absolute offset into the file to write the bytes.
    /// - Returns: The number of bytes written.
    /// - Throws: ``FileSystemError/Code-swift.struct/unsupported`` if file is
    /// unseekable and `offset` is not 0.
    @discardableResult
    public func write(
        contentsOf buffer: ByteBuffer,
        toAbsoluteOffset offset: Int64
    ) async throws -> Int64 {
        try await self.write(contentsOf: buffer.readableBytesView, toAbsoluteOffset: offset)
    }
}

// MARK: - File times modifiers

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension FileHandleProtocol {
    /// Sets the file's last access time to the given time.
    ///
    /// - Parameter time: The time to which the file's last access time should be set.
    ///
    /// - Throws: If there's an error updating the time. If this happens, the original value won't be modified.
    public func setLastAccessTime(to time: FileInfo.Timespec) async throws {
        try await self.setTimes(lastAccess: time, lastDataModification: nil)
    }

    /// Sets the file's last data modification time to the given time.
    ///
    /// - Parameter time: The time to which the file's last data modification time should be set.
    ///
    /// - Throws: If there's an error updating the time. If this happens, the original value won't be modified.
    public func setLastDataModificationTime(to time: FileInfo.Timespec) async throws {
        try await self.setTimes(lastAccess: nil, lastDataModification: time)
    }

    /// Sets the file's last access and last data modification times to the current time.
    ///
    /// - Throws: If there's an error updating the times. If this happens, the original values won't be modified.
    public func touch() async throws {
        try await self.setTimes(lastAccess: nil, lastDataModification: nil)
    }
}

/// A file handle which is suitable for reading and writing.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public typealias ReadableAndWritableFileHandleProtocol = ReadableFileHandleProtocol
    & WritableFileHandleProtocol

// MARK: - Directory

/// A handle suitable for directories.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public protocol DirectoryFileHandleProtocol: FileHandleProtocol {
    /// The type of ``ReadableFileHandleProtocol`` to return when opening files for reading.
    associatedtype ReadFileHandle: ReadableFileHandleProtocol

    /// The type of ``WritableFileHandleProtocol`` to return when opening files for writing.
    associatedtype WriteFileHandle: WritableFileHandleProtocol

    /// The type of ``ReadableAndWritableFileHandleProtocol`` to return when opening files for reading and writing.
    associatedtype ReadWriteFileHandle: ReadableAndWritableFileHandleProtocol

    /// Returns an `AsyncSequence` of entries in the open directory.
    ///
    /// You can recurse into and list the contents of any subdirectories by setting `recursive`
    /// to `true`. The current (".") and parent ("..") directory entries are not included. The order
    /// of entries is arbitrary and shouldn't be relied upon.
    ///
    /// - Parameter recursive: Whether subdirectories should be recursively visited.
    /// - Returns: An `AsyncSequence` of directory entries.
    func listContents(recursive: Bool) -> DirectoryEntries

    /// Opens the file at `path` for reading and returns a handle to it.
    ///
    /// If `path` is a relative path then it is opened relative to the handle. The file being
    /// opened must already exist otherwise this function will throw a ``FileSystemError`` with
    /// code ``FileSystemError/Code-swift.struct/notFound``.
    ///
    /// - Parameters:
    ///   - path: The path of the directory to open relative to the open file.
    ///   - options: How the file should be opened.
    /// - Returns: A read-only handle to the opened file.
    func openFile(
        forReadingAt path: FilePath,
        options: OpenOptions.Read
    ) async throws -> ReadFileHandle

    /// Opens the file at `path` for writing and returns a handle to it.
    ///
    /// If `path` is a relative path then it is opened relative to the handle.
    ///
    /// - Parameters:
    ///   - path: The path of the file to open relative to the open file.
    ///   - options: How the file should be opened.
    /// - Returns: A write-only handle to the opened file.
    func openFile(
        forWritingAt path: FilePath,
        options: OpenOptions.Write
    ) async throws -> WriteFileHandle

    /// Opens the file at `path` for reading and writing and returns a handle to it.
    ///
    /// If `path` is a relative path then it is opened relative to the handle.
    ///
    /// - Parameters:
    ///   - path: The path of the file to open relative to the open file.
    ///   - options: How the file should be opened.
    func openFile(
        forReadingAndWritingAt path: FilePath,
        options: OpenOptions.Write
    ) async throws -> ReadWriteFileHandle

    /// Opens the directory at `path` and returns a handle to it.
    ///
    /// The directory being opened must already exist otherwise this function will throw an error.
    /// If `path` is a relative path then it is opened relative to the handle.
    ///
    /// - Parameters:
    ///   - path: The path of the directory to open.
    ///   - options: How the file should be opened.
    /// - Returns: A handle to the opened directory.
    func openDirectory(
        atPath path: FilePath,
        options: OpenOptions.Directory
    ) async throws -> Self
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension DirectoryFileHandleProtocol {
    /// Returns an `AsyncSequence` of entries in the open directory.
    ///
    /// The current (".") and parent ("..") directory entries are not included. The order of entries
    /// is arbitrary and should not be relied upon.
    public func listContents() -> DirectoryEntries {
        self.listContents(recursive: false)
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension DirectoryFileHandleProtocol {
    /// Opens the file at the given path and provides scoped read access to it.
    ///
    /// The file remains open during lifetime of the `execute` block and will be closed
    /// automatically before the call returns. Files may also be opened in write-only and read-write
    /// mode by calling ``DirectoryFileHandleProtocol/withFileHandle(forWritingAt:options:execute:)-36f0k``
    /// and ``DirectoryFileHandleProtocol/withFileHandle(forReadingAndWritingAt:options:execute:)-5j0f3``,
    /// respectively.
    ///
    /// If `path` is a relative path then it is opened relative to the handle. The file being
    /// opened must already exist otherwise this function will throw a ``FileSystemError`` with
    /// code ``FileSystemError/Code-swift.struct/notFound``.
    ///
    /// - Parameters:
    ///   - path: The path of the file to open for reading.
    ///   - options: How the file should be opened.
    ///   - body: A closure which provides read-only access to the open file. The file is closed
    ///       automatically after the closure exits.
    /// - Important: The handle passed to `execute` must not escape the closure.
    /// - Returns: The result of the `execute` closure.
    public func withFileHandle<Result>(
        forReadingAt path: FilePath,
        options: OpenOptions.Read = OpenOptions.Read(),
        execute body: (_ read: ReadFileHandle) async throws -> Result
    ) async throws -> Result {
        let handle = try await self.openFile(forReadingAt: path, options: options)

        return try await withUncancellableTearDown {
            try await body(handle)
        } tearDown: { _ in
            try await handle.close()
        }
    }

    /// Opens the file at the given path and provides scoped write access to it.
    ///
    /// The file remains open during lifetime of the `execute` block and will be closed
    /// automatically before the call returns. Files may also be opened in read-only or read-write
    /// mode by calling ``DirectoryFileHandleProtocol/withFileHandle(forReadingAt:options:execute:)-52xsn`` and
    /// ``DirectoryFileHandleProtocol/withFileHandle(forReadingAndWritingAt:options:execute:)-5j0f3``,
    /// respectively.
    ///
    /// If `path` is a relative path then it is opened relative to the handle.
    ///
    /// - Parameters:
    ///   - path: The path of the file to open for reading.
    ///   - options: How the file should be opened.
    ///   - body: A closure which provides write-only access to the open file. The file is closed
    ///       automatically after the closure exits.
    /// - Important: The handle passed to `execute` must not escape the closure.
    /// - Returns: The result of the `execute` closure.
    public func withFileHandle<Result>(
        forWritingAt path: FilePath,
        options: OpenOptions.Write = .newFile(replaceExisting: false),
        execute body: (_ write: WriteFileHandle) async throws -> Result
    ) async throws -> Result {
        let handle = try await self.openFile(forWritingAt: path, options: options)

        return try await withUncancellableTearDown {
            try await body(handle)
        } tearDown: { result in
            switch result {
            case .success:
                try await handle.close(makeChangesVisible: true)
            case .failure:
                try await handle.close(makeChangesVisible: false)
            }
        }
    }

    /// Opens the file at the given path and provides scoped read-write access to it.
    ///
    /// The file remains open during lifetime of the `execute` block and will be closed
    /// automatically before the call returns. Files may also be opened in read-only or write-only
    /// mode by calling ``DirectoryFileHandleProtocol/withFileHandle(forReadingAt:options:execute:)-52xsn`` and
    /// ``DirectoryFileHandleProtocol/withFileHandle(forWritingAt:options:execute:)-36f0k``, respectively.
    ///
    /// If `path` is a relative path then it is opened relative to the handle.
    ///
    /// - Parameters:
    ///   - path: The path of the file to open for reading and writing.
    ///   - options: How the file should be opened.
    ///   - body: A closure which provides access to the open file. The file is closed
    ///       automatically after the closure exits.
    /// - Important: The handle passed to `execute` must not escape the closure.
    /// - Returns: The result of the `execute` closure.
    public func withFileHandle<Result>(
        forReadingAndWritingAt path: FilePath,
        options: OpenOptions.Write = .newFile(replaceExisting: false),
        execute body: (_ readWrite: ReadWriteFileHandle) async throws -> Result
    ) async throws -> Result {
        let handle = try await self.openFile(forReadingAndWritingAt: path, options: options)

        return try await withUncancellableTearDown {
            try await body(handle)
        } tearDown: { result in
            switch result {
            case .success:
                try await handle.close(makeChangesVisible: true)
            case .failure:
                try await handle.close(makeChangesVisible: false)
            }
        }
    }

    /// Opens the directory at the given path and provides scoped access to it.
    ///
    /// - Parameters:
    ///   - path: The path of the directory to open.
    ///   - options: How the directory should be opened.
    ///   - body: A closure which provides access to the directory.
    /// - Important: The handle passed to `execute` must not escape the closure.
    /// - Returns: The result of the `execute` closure.
    public func withDirectoryHandle<Result>(
        atPath path: FilePath,
        options: OpenOptions.Directory = OpenOptions.Directory(),
        execute body: (_ directory: Self) async throws -> Result
    ) async throws -> Result {
        let handle = try await self.openDirectory(atPath: path, options: options)

        return try await withUncancellableTearDown {
            try await body(handle)
        } tearDown: { _ in
            try await handle.close()
        }
    }
}
