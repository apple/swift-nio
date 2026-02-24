//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
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

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
@preconcurrency import Glibc
import CNIOLinux
#elseif canImport(Musl)
@preconcurrency import Musl
import CNIOLinux
#elseif canImport(Bionic)
@preconcurrency import Bionic
import CNIOLinux
#endif

extension FileDescriptor {
    /// Opens or creates a file for reading or writing.
    ///
    /// The corresponding C function is `fdopenat`.
    ///
    /// - Parameters:
    ///   - path: The location of the file to open. If the path is relative then the file is opened
    ///       relative to the descriptor.
    ///   - mode: The read and write access to use.
    ///   - options: The behavior for opening the file.
    ///   - permissions: The file permissions to use for created files.
    ///   - retryOnInterrupt: Whether to retry the operation if it throws `Errno.interrupted`. The
    ///       default is true. Pass false to try only once and throw an error upon interruption.
    /// - Returns: A file descriptor for the open file.
    @_spi(Testing)
    public func `open`(
        atPath path: FilePath,
        mode: FileDescriptor.AccessMode,
        options: FileDescriptor.OpenOptions,
        permissions: FilePermissions?,
        retryOnInterrupt: Bool = true
    ) -> Result<FileDescriptor, Errno> {
        let oFlag = mode.rawValue | options.rawValue
        let rawValue = valueOrErrno(retryOnInterrupt: retryOnInterrupt) {
            path.withPlatformString {
                if let permissions = permissions {
                    return system_fdopenat(self.rawValue, $0, oFlag, permissions.rawValue)
                } else {
                    precondition(!options.contains(.create), "Create must be given permissions")
                    return system_fdopenat(self.rawValue, $0, oFlag)
                }
            }
        }

        return rawValue.map { FileDescriptor(rawValue: $0) }
    }

    /// Returns information about the status of the open file.
    ///
    /// The corresponding C function is `fstat`.
    ///
    /// - Returns: Information about the open file.
    @_spi(Testing)
    public func status() -> Result<CInterop.Stat, Errno> {
        var status = CInterop.Stat()
        return nothingOrErrno(retryOnInterrupt: false) {
            system_fstat(self.rawValue, &status)
        }.map { status }
    }

    /// Sets the permission bits of the open file.
    ///
    /// The corresponding C function is `fchmod`.
    ///
    /// - Parameters:
    ///   - mode: The permissions to set on the file.
    ///   - retryOnInterrupt: Whether to retry the operation if it throws `Errno.interrupted`. The
    ///       default is true. Pass false to try only once and throw an error upon interruption.
    @_spi(Testing)
    public func changeMode(
        _ mode: FilePermissions,
        retryOnInterrupt: Bool = true
    ) -> Result<Void, Errno> {
        nothingOrErrno(retryOnInterrupt: retryOnInterrupt) {
            system_fchmod(self.rawValue, mode.rawValue)
        }
    }

    /// List the names of extended attributes.
    ///
    /// The corresponding C function is `flistxattr`.
    ///
    /// - Parameter buffer: The buffer into which names are written. Names are written are NULL
    ///     terminated UTF-8 strings and are returned in an arbitrary order. There is no padding
    ///     between strings. If `buffer` is `nil` then the return value is the size of the buffer
    ///     required to list all extended attributes. If there is not enough space in the `buffer`
    ///     then `Errno.outOfRange` is returned.
    /// - Returns: The size of the extended attribute list.
    @_spi(Testing)
    public func listExtendedAttributes(
        _ buffer: UnsafeMutableBufferPointer<CChar>?
    ) -> Result<Int, Errno> {
        valueOrErrno(retryOnInterrupt: false) {
            system_flistxattr(self.rawValue, buffer?.baseAddress, buffer?.count ?? 0)
        }
    }

    /// Get the value of the named extended attribute.
    ///
    /// The corresponding C function is `fgetxattr`.
    ///
    /// - Parameters:
    ///   - name: The name of the extended attribute.
    ///   - buffer: The buffer into which the value is written. If `buffer` is `nil` then the return
    ///       value is the size of the buffer required to read the value. If there is not enough
    ///       space in the `buffer` then `Errno.outOfRange` is returned.
    /// - Returns: The size of the extended attribute value.
    @_spi(Testing)
    public func getExtendedAttribute(
        named name: String,
        buffer: UnsafeMutableRawBufferPointer?
    ) -> Result<Int, Errno> {
        valueOrErrno(retryOnInterrupt: false) {
            name.withPlatformString {
                system_fgetxattr(self.rawValue, $0, buffer?.baseAddress, buffer?.count ?? 0)
            }
        }
    }

    /// Set the value of the named extended attribute.
    ///
    /// The corresponding C function is `fsetxattr`.
    ///
    /// - Parameters:
    ///   - name: The name of the extended attribute.
    ///   - value: The data to set for the attribute.
    @_spi(Testing)
    public func setExtendedAttribute(
        named name: String,
        to value: UnsafeRawBufferPointer?
    ) -> Result<Void, Errno> {
        nothingOrErrno(retryOnInterrupt: false) {
            name.withPlatformString { namePointer in
                system_fsetxattr(self.rawValue, namePointer, value?.baseAddress, value?.count ?? 0)
            }
        }
    }

    /// Remove the value for the named extended attribute.
    ///
    /// The corresponding C function is `fremovexattr`.
    ///
    /// - Parameters:
    ///   - name: The name of the extended attribute.
    @_spi(Testing)
    public func removeExtendedAttribute(_ name: String) -> Result<Void, Errno> {
        nothingOrErrno(retryOnInterrupt: false) {
            name.withPlatformString {
                system_fremovexattr(self.rawValue, $0)
            }
        }
    }

    /// Synchronize modified data and metadata to a permanent storage device.
    ///
    /// The corresponding C functions is `fsync`.
    ///
    /// - Parameter retryOnInterrupt: Whether the call should be retried on `Errno.interrupted`.
    @_spi(Testing)
    public func synchronize(retryOnInterrupt: Bool = true) -> Result<Void, Errno> {
        nothingOrErrno(retryOnInterrupt: retryOnInterrupt) {
            system_fsync(self.rawValue)
        }
    }

    /// Returns a pointer to a directory structure.
    ///
    /// The corresponding C function is `fdopendir`
    ///
    /// - Important: Calling this function cedes ownership of the file descriptor to the system. The
    ///     caller should not modify the descriptor or close the descriptor via `close()`. Once
    ///     directory iteration has been completed then `Libc.closdir(_:)` must be called.
    internal func opendir() -> Result<CInterop.DirPointer, Errno> {
        valueOrErrno(retryOnInterrupt: false) {
            libc_fdopendir(self.rawValue)
        }
    }
}

extension FileDescriptor {
    func listExtendedAttributes() -> Result<[String], Errno> {
        // Required capacity is returned if a no buffer is passed to flistxattr.
        self.listExtendedAttributes(nil).flatMap { capacity in
            guard capacity > 0 else {
                // Required capacity is zero: no attributes to read.
                return .success([])
            }

            // Read and decode.
            var buffer = [UInt8](repeating: 0, count: capacity)
            return buffer.withUnsafeMutableBufferPointer { pointer in
                pointer.withMemoryRebound(to: CChar.self) { buffer in
                    self.listExtendedAttributes(buffer)
                }
            }.map { size in
                // The buffer contains null terminated C-strings.
                var attributes = [String]()
                var slice = buffer.prefix(size)
                while let index = slice.firstIndex(of: 0) {
                    // TODO: can we do this more cheaply?
                    let prefix = slice[..<index]
                    attributes.append(String(decoding: Array(prefix), as: UTF8.self))
                    slice = slice.dropFirst(prefix.count + 1)
                }

                return attributes
            }
        }
    }

    func readExtendedAttribute(named name: String) -> Result<[UInt8], Errno> {
        // Required capacity is returned if a no buffer is passed to fgetxattr.
        self.getExtendedAttribute(named: name, buffer: nil).flatMap { capacity in
            guard capacity > 0 else {
                // Required capacity is zero: no values to read.
                return .success([])
            }

            // Read and decode.
            var buffer = [UInt8](repeating: 0, count: capacity)
            return buffer.withUnsafeMutableBytes { bytes in
                self.getExtendedAttribute(named: name, buffer: bytes)
            }.map { size in
                // Remove any trailing zeros.
                buffer.removeLast(buffer.count - size)
                return buffer
            }
        }
    }
}

extension FileDescriptor {
    func readChunk(fromAbsoluteOffset offset: Int64, length: Int64) -> Result<ByteBuffer, Error> {
        self._readChunk(fromAbsoluteOffset: offset, length: length)
    }

    func readChunk(length: Int64) -> Result<ByteBuffer, Error> {
        self._readChunk(fromAbsoluteOffset: nil, length: length)
    }

    private func _readChunk(
        fromAbsoluteOffset offset: Int64?,
        length: Int64
    ) -> Result<ByteBuffer, Error> {
        // This is used by the `FileChunks` and means we allocate for every chunk that we read for
        // the file. That's fine for now because the syscall cost is likely to be the dominant
        // factor here. However we should investigate whether it's possible to have a pool of
        // buffers which we can reuse. This would need to be at least as large as the high watermark
        // of the chunked file for it to be useful.
        Result {
            var buffer = ByteBuffer()
            try buffer.writeWithUnsafeMutableBytes(minimumWritableBytes: Int(length)) { buffer in
                let bufferPointer: UnsafeMutableRawBufferPointer

                // Don't vend a buffer which is larger than `length`; we can read less but we must
                // not read more.
                if length < buffer.count {
                    bufferPointer = UnsafeMutableRawBufferPointer(
                        start: buffer.baseAddress,
                        count: Int(length)
                    )
                } else {
                    bufferPointer = buffer
                }

                if let offset {
                    return try self.read(fromAbsoluteOffset: offset, into: bufferPointer)
                } else {
                    return try self.read(into: bufferPointer)
                }
            }
            return buffer
        }
    }
}

extension FileDescriptor {
    func write(
        contentsOf bytes: some Sequence<UInt8>,
        toAbsoluteOffset offset: Int64
    ) -> Result<Int64, Error> {
        Result {
            Int64(try self.writeAll(toAbsoluteOffset: offset, bytes))
        }
    }

    func write(
        contentsOf bytes: some Sequence<UInt8>
    ) -> Result<Int64, Error> {
        Result {
            Int64(try self.writeAll(bytes))
        }
    }
}

#if canImport(Glibc) || canImport(Musl) || canImport(Bionic)
extension FileDescriptor.OpenOptions {
    static var temporaryFile: Self {
        Self(rawValue: CNIOLinux_O_TMPFILE)
    }
}

extension FileDescriptor {
    static var currentWorkingDirectory: Self {
        Self(rawValue: AT_FDCWD)
    }
}
#endif
