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

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux) || os(Android)
import SystemPackage

#if canImport(Darwin)
import Darwin
import CNIODarwin
#elseif canImport(Glibc)
import Glibc
import CNIOLinux
#elseif canImport(Musl)
import Musl
import CNIOLinux
#endif

@_spi(Testing)
public enum Syscall {
    @_spi(Testing)
    public static func stat(path: FilePath) -> Result<CInterop.Stat, Errno> {
        return path.withPlatformString { platformPath in
            var status = CInterop.Stat()
            return valueOrErrno(retryOnInterrupt: false) {
                system_stat(platformPath, &status)
            }.map { _ in
                status
            }
        }
    }

    @_spi(Testing)
    public static func lstat(path: FilePath) -> Result<CInterop.Stat, Errno> {
        return path.withPlatformString { platformPath in
            var status = CInterop.Stat()
            return valueOrErrno(retryOnInterrupt: false) {
                system_lstat(platformPath, &status)
            }.map { _ in
                status
            }
        }
    }

    @_spi(Testing)
    public static func mkdir(at path: FilePath, permissions: FilePermissions) -> Result<Void, Errno> {
        return nothingOrErrno(retryOnInterrupt: false) {
            path.withPlatformString { p in
                system_mkdir(p, permissions.rawValue)
            }
        }
    }

    @_spi(Testing)
    public static func rename(from old: FilePath, to new: FilePath) -> Result<Void, Errno> {
        return nothingOrErrno(retryOnInterrupt: false) {
            old.withPlatformString { oldPath in
                new.withPlatformString { newPath in
                    system_rename(oldPath, newPath)
                }
            }
        }
    }

    #if canImport(Darwin)
    @_spi(Testing)
    public static func rename(
        from old: FilePath,
        to new: FilePath,
        options: RenameOptions
    ) -> Result<Void, Errno> {
        return nothingOrErrno(retryOnInterrupt: false) {
            old.withPlatformString { oldPath in
                new.withPlatformString { newPath in
                    system_renamex_np(oldPath, newPath, options.rawValue)
                }
            }
        }
    }

    @_spi(Testing)
    public struct RenameOptions: OptionSet {
        public var rawValue: CUnsignedInt

        public init(rawValue: CUnsignedInt) {
            self.rawValue = rawValue
        }

        public static var exclusive: Self {
            return Self(rawValue: UInt32(bitPattern: RENAME_EXCL))
        }

        public static var swap: Self {
            return Self(rawValue: UInt32(bitPattern: RENAME_SWAP))
        }
    }
    #endif

    #if canImport(Glibc) || canImport(Musl)
    @_spi(Testing)
    public static func rename(
        from old: FilePath,
        relativeTo oldFD: FileDescriptor,
        to new: FilePath,
        relativeTo newFD: FileDescriptor,
        flags: RenameAtFlags
    ) -> Result<Void, Errno> {
        return nothingOrErrno(retryOnInterrupt: false) {
            old.withPlatformString { oldPath in
                new.withPlatformString { newPath in
                    system_renameat2(
                        oldFD.rawValue,
                        oldPath,
                        newFD.rawValue,
                        newPath,
                        flags.rawValue
                    )
                }
            }
        }
    }

    @_spi(Testing)
    public struct RenameAtFlags: OptionSet {
        public var rawValue: CUnsignedInt

        public init(rawValue: CUnsignedInt) {
            self.rawValue = rawValue
        }

        public static var exclusive: Self {
            return Self(rawValue: CNIOLinux_RENAME_NOREPLACE)
        }

        public static var swap: Self {
            return Self(rawValue: CNIOLinux_RENAME_EXCHANGE)
        }
    }
    #endif

    #if canImport(Glibc) || canImport(Musl)
    @_spi(Testing)
    public struct LinkAtFlags: OptionSet {
        @_spi(Testing)
        public var rawValue: CInt

        @_spi(Testing)
        public init(rawValue: CInt) {
            self.rawValue = rawValue
        }

        @_spi(Testing)
        public static var emptyPath: Self {
            Self(rawValue: CNIOLinux_AT_EMPTY_PATH)
        }

        @_spi(Testing)
        public static var followSymbolicLinks: Self {
            Self(rawValue: AT_SYMLINK_FOLLOW)
        }
    }

    @_spi(Testing)
    public static func linkAt(
        from source: FilePath,
        relativeTo sourceFD: FileDescriptor,
        to destination: FilePath,
        relativeTo destinationFD: FileDescriptor,
        flags: LinkAtFlags
    ) -> Result<Void, Errno> {
        return nothingOrErrno(retryOnInterrupt: false) {
            source.withPlatformString { src in
                destination.withPlatformString { dst in
                    system_linkat(
                        sourceFD.rawValue,
                        src,
                        destinationFD.rawValue,
                        dst,
                        flags.rawValue
                    )
                }
            }
        }
    }
    #endif

    @_spi(Testing)
    public static func symlink(
        to destination: FilePath,
        from source: FilePath
    ) -> Result<Void, Errno> {
        return nothingOrErrno(retryOnInterrupt: false) {
            source.withPlatformString { src in
                destination.withPlatformString { dst in
                    system_symlink(dst, src)
                }
            }
        }
    }

    @_spi(Testing)
    public static func readlink(at path: FilePath) -> Result<FilePath, Errno> {
        do {
            let resolved = try path.withPlatformString { p in
                try String(customUnsafeUninitializedCapacity: Int(CInterop.maxPathLength)) { pointer in
                    let result = pointer.withMemoryRebound(to: CInterop.PlatformChar.self) { ptr in
                        valueOrErrno(retryOnInterrupt: false) {
                            system_readlink(p, ptr.baseAddress!, ptr.count)
                        }
                    }
                    return try result.get()
                }
            }
            return .success(FilePath(resolved))
        } catch let error as Errno {
            return .failure(error)
        } catch {
            // Shouldn't happen: we deal in Result types and only ever with Errno.
            fatalError("Unexpected error '\(error)' caught")
        }
    }

    #if canImport(Glibc) || canImport(Musl)
    @_spi(Testing)
    public static func sendfile(
        to output: FileDescriptor,
        from input: FileDescriptor,
        offset: Int,
        size: Int
    ) -> Result<Int, Errno> {
        valueOrErrno(retryOnInterrupt: false) {
            system_sendfile(output.rawValue, input.rawValue, offset, size)
        }
    }
    #endif
}

@_spi(Testing)
public enum Libc {
    static func readdir(
        _ dir: CInterop.DirPointer
    ) -> Result<UnsafeMutablePointer<CInterop.DirEnt>?, Errno> {
        optionalValueOrErrno(retryOnInterrupt: false) {
            libc_readdir(dir)
        }
    }

    static func closedir(
        _ dir: CInterop.DirPointer
    ) -> Result<Void, Errno> {
        nothingOrErrno(retryOnInterrupt: false) {
            libc_closedir(dir)
        }
    }

    #if canImport(Darwin)
    @_spi(Testing)
    public static func fcopyfile(
        from source: FileDescriptor,
        to destination: FileDescriptor,
        state: copyfile_state_t?,
        flags: copyfile_flags_t
    ) -> Result<Void, Errno> {
        nothingOrErrno(retryOnInterrupt: false) {
            libc_fcopyfile(source.rawValue, destination.rawValue, state, flags)
        }
    }
    #endif

    @_spi(Testing)
    public static func remove(
        _ path: FilePath
    ) -> Result<Void, Errno> {
        nothingOrErrno(retryOnInterrupt: false) {
            path.withPlatformString {
                libc_remove($0)
            }
        }
    }

    static func getcwd() -> Result<FilePath, Errno> {
        var buffer = [CInterop.PlatformChar](
            repeating: 0,
            count: Int(CInterop.maxPathLength)
        )

        return optionalValueOrErrno(retryOnInterrupt: false) {
            buffer.withUnsafeMutableBufferPointer { pointer in
                libc_getcwd(pointer.baseAddress!, pointer.count)
            }
        }.map { ptr in
            // 'ptr' is just the input pointer, we should ignore it and just rely on the bytes
            // in buffer.
            //
            // At this point 'ptr' must be non-nil, because if it were 'nil' we should be on the
            // error path.
            precondition(ptr != nil)
            return FilePath(platformString: buffer)
        }
    }

    #if !os(Android)
    static func constr(_ name: CInt) -> Result<String, Errno> {
        var buffer = [CInterop.PlatformChar](repeating: 0, count: 128)

        repeat {
            let result = valueOrErrno(retryOnInterrupt: false) {
                buffer.withUnsafeMutableBufferPointer { pointer in
                    libc_confstr(name, pointer.baseAddress!, pointer.count)
                }
            }

            switch result {
            case let .success(length):
                if length <= buffer.count {
                    return .success(String(cString: buffer))
                } else {
                    // The buffer wasn't long enough. Double and try again.
                    buffer.append(contentsOf: repeatElement(0, count: buffer.capacity))
                }
            case let .failure(errno):
                return .failure(errno)
            }
        } while true
    }
    #endif

    static func ftsOpen(_ path: FilePath, options: FTSOpenOptions) -> Result<CInterop.FTSPointer, Errno> {
        // 'fts_open' needs an unsafe mutable pointer to the C-string, `FilePath` doesn't offer this
        // so copy out its bytes.
        var pathBytes = path.withPlatformString { pointer in
            // Length excludes the null terminator, so add it back.
            let bufferPointer = UnsafeBufferPointer(start: pointer, count: path.length + 1)
            return Array(bufferPointer)
        }

        return valueOrErrno {
            pathBytes.withUnsafeMutableBufferPointer { pointer in
                // The array must be terminated with a nil.
                libc_fts_open([pointer.baseAddress, nil], options.rawValue)
            }
        }
    }

    /// Options passed to 'fts_open'.
    struct FTSOpenOptions: OptionSet {
        var rawValue: CInt

        /// Don't change directory while walking the filesystem hierarchy.
        static var noChangeDir: Self { Self(rawValue: FTS_NOCHDIR) }

        /// Return FTS entries for symbolic links rather than their targets.
        static var physical: Self { Self(rawValue: FTS_PHYSICAL) }

        /// Return FTS entries for the targets of symbolic links.
        static var logical: Self { Self(rawValue: FTS_LOGICAL) }
    }

    static func ftsRead(
        _ pointer: CInterop.FTSPointer
    ) -> Result<UnsafeMutablePointer<CInterop.FTSEnt>?, Errno> {
        optionalValueOrErrno {
            libc_fts_read(pointer)
        }
    }

    static func ftsClose(
        _ pointer: CInterop.FTSPointer
    ) -> Result<Void, Errno> {
        nothingOrErrno {
            libc_fts_close(pointer)
        }
    }
}
#endif
