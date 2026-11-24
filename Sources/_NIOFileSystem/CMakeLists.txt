##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

add_library(_NIOFileSystem
  "Array+FileSystem.swift"
  "ArraySlice+FileSystem.swift"
  "BufferedReader.swift"
  "BufferedWriter.swift"
  "ByteBuffer+FileSystem.swift"
  "ByteCount.swift"
  "Convenience.swift"
  "DirectoryEntries.swift"
  "DirectoryEntry.swift"
  "Exports.swift"
  "FileChunks.swift"
  "FileHandle.swift"
  "FileHandleProtocol.swift"
  "FileInfo.swift"
  "FileSystem.swift"
  "FileSystemError+Syscall.swift"
  "FileSystemError.swift"
  "FileSystemProtocol.swift"
  "FileType.swift"
  "IOStrategy.swift"
  "Internal/BufferedOrAnyStream.swift"
  "Internal/BufferedStream.swift"
  "Internal/Cancellation.swift"
  "Internal/Concurrency Primitives/TokenBucket.swift"
  "Internal/ParallelDirCopy.swift"
  "Internal/ParallelRemoval.swift"
  "Internal/String+UnsafeUnititializedCapacity.swift"
  "Internal/System Calls/CInterop.swift"
  "Internal/System Calls/Errno.swift"
  "Internal/System Calls/FileDescriptor+Syscalls.swift"
  "Internal/System Calls/Mocking.swift"
  "Internal/System Calls/Syscall.swift"
  "Internal/System Calls/Syscalls.swift"
  "Internal/System Calls/SystemPackage+Windows.swift"
  "Internal/SystemFileHandle.swift"
  "Internal/Utilities.swift"
  "NIOFilePath.swift"
  "NIOFileSystemSendableMetatype.swift"
  "OpenOptions.swift"
  "String+FileSystem.swift"
)

target_link_libraries(_NIOFileSystem PUBLIC
  NIOCore
  NIOPosix
  NIOConcurrencyHelpers
  CNIOLinux
  CNIODarwin
  CNIOWindows
  SwiftAtomics::Atomics
  SwiftCollections::DequeModule
  SwiftSystem::SystemPackage)

target_compile_options(_NIOFileSystem PRIVATE ${SWIFT_NIO_COMPILE_OPTIONS})
# ENABLE_MOCKING (defined for debug builds in Package.swift) is deliberately not defined here: it only adds the
# `@_spi(Testing)` syscall-mocking hooks that are used by NIOFSTests.
target_compile_definitions(_NIOFileSystem PRIVATE $<$<NOT:$<CONFIG:Release,RelWithDebInfo,MinSizeRel>>:DEBUG>)
set_target_properties(_NIOFileSystem PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

swift_nio_install_target(_NIOFileSystem)
set_property(GLOBAL APPEND PROPERTY SWIFT_NIO_EXPORTS _NIOFileSystem)
