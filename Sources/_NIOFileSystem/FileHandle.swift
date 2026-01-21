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

/// Provides a ``FileHandle``.
///
/// Users should not implement or rely on this protocol; its purpose is to reduce boilerplate
/// by providing a default implementation of ``FileHandleProtocol`` for types which hold
/// a ``FileHandle``.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public protocol _HasFileHandle: FileHandleProtocol {
    var fileHandle: FileHandle { get }
}

// Provides an implementation of `FileHandleProtocol` by calling through to `FileHandle`.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension _HasFileHandle {
    public func info() async throws -> FileInfo {
        try await self.fileHandle.info()
    }

    public func replacePermissions(_ permissions: FilePermissions) async throws {
        try await self.fileHandle.replacePermissions(permissions)
    }

    public func addPermissions(_ permissions: FilePermissions) async throws -> FilePermissions {
        try await self.fileHandle.addPermissions(permissions)
    }

    public func removePermissions(_ permissions: FilePermissions) async throws -> FilePermissions {
        try await self.fileHandle.removePermissions(permissions)
    }

    public func attributeNames() async throws -> [String] {
        try await self.fileHandle.attributeNames()
    }

    public func valueForAttribute(_ name: String) async throws -> [UInt8] {
        try await self.fileHandle.valueForAttribute(name)
    }

    public func updateValueForAttribute(
        _ bytes: some (Sendable & RandomAccessCollection<UInt8>),
        attribute name: String
    ) async throws {
        try await self.fileHandle.updateValueForAttribute(bytes, attribute: name)
    }

    public func removeValueForAttribute(_ name: String) async throws {
        try await self.fileHandle.removeValueForAttribute(name)
    }

    public func synchronize() async throws {
        try await self.fileHandle.synchronize()
    }

    public func withUnsafeDescriptor<R: Sendable>(
        _ execute: @Sendable @escaping (FileDescriptor) throws -> R
    ) async throws -> R {
        try await self.fileHandle.withUnsafeDescriptor {
            try execute($0)
        }
    }

    public func detachUnsafeFileDescriptor() throws -> FileDescriptor {
        try self.fileHandle.detachUnsafeFileDescriptor()
    }

    public func close() async throws {
        try await self.fileHandle.close()
    }

    public func setTimes(
        lastAccess: FileInfo.Timespec?,
        lastDataModification: FileInfo.Timespec?
    ) async throws {
        try await self.fileHandle.setTimes(
            lastAccess: lastAccess,
            lastDataModification: lastDataModification
        )
    }
}

/// Implements ``FileHandleProtocol`` by making system calls to interact with the local file system.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct FileHandle: FileHandleProtocol, Sendable {
    internal let systemFileHandle: SystemFileHandle

    internal init(wrapping handle: SystemFileHandle) {
        self.systemFileHandle = handle
    }

    public func info() async throws -> FileInfo {
        try await self.systemFileHandle.info()
    }

    public func replacePermissions(_ permissions: FilePermissions) async throws {
        try await self.systemFileHandle.replacePermissions(permissions)
    }

    public func addPermissions(_ permissions: FilePermissions) async throws -> FilePermissions {
        try await self.systemFileHandle.addPermissions(permissions)
    }

    public func removePermissions(_ permissions: FilePermissions) async throws -> FilePermissions {
        try await self.systemFileHandle.removePermissions(permissions)
    }

    public func attributeNames() async throws -> [String] {
        try await self.systemFileHandle.attributeNames()
    }

    public func valueForAttribute(_ name: String) async throws -> [UInt8] {
        try await self.systemFileHandle.valueForAttribute(name)
    }

    public func updateValueForAttribute(
        _ bytes: some (Sendable & RandomAccessCollection<UInt8>),
        attribute name: String
    ) async throws {
        try await self.systemFileHandle.updateValueForAttribute(bytes, attribute: name)
    }

    public func removeValueForAttribute(_ name: String) async throws {
        try await self.systemFileHandle.removeValueForAttribute(name)
    }

    public func synchronize() async throws {
        try await self.systemFileHandle.synchronize()
    }

    public func withUnsafeDescriptor<R: Sendable>(
        _ execute: @Sendable @escaping (FileDescriptor) throws -> R
    ) async throws -> R {
        try await self.systemFileHandle.withUnsafeDescriptor {
            try execute($0)
        }
    }

    public func detachUnsafeFileDescriptor() throws -> FileDescriptor {
        try self.systemFileHandle.detachUnsafeFileDescriptor()
    }

    public func close() async throws {
        try await self.systemFileHandle.close()
    }

    public func setTimes(
        lastAccess: FileInfo.Timespec?,
        lastDataModification: FileInfo.Timespec?
    ) async throws {
        try await self.systemFileHandle.setTimes(
            lastAccess: lastAccess,
            lastDataModification: lastDataModification
        )
    }
}

/// Implements ``ReadableFileHandleProtocol`` by making system calls to interact with the local
/// file system.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct ReadFileHandle: ReadableFileHandleProtocol, _HasFileHandle, Sendable {
    public let fileHandle: FileHandle

    internal init(wrapping systemFileHandle: SystemFileHandle) {
        self.fileHandle = FileHandle(wrapping: systemFileHandle)
    }

    public func readChunk(
        fromAbsoluteOffset offset: Int64,
        length: ByteCount
    ) async throws -> ByteBuffer {
        try await self.fileHandle.systemFileHandle.readChunk(
            fromAbsoluteOffset: offset,
            length: length
        )
    }

    public func readChunks(in range: Range<Int64>, chunkLength: ByteCount) -> FileChunks {
        self.fileHandle.systemFileHandle.readChunks(in: range, chunkLength: chunkLength)
    }

    public func setTimes(
        lastAccess: FileInfo.Timespec?,
        lastDataModification: FileInfo.Timespec?
    ) async throws {
        try await self.fileHandle.systemFileHandle.setTimes(
            lastAccess: lastAccess,
            lastDataModification: lastDataModification
        )
    }
}

/// Implements ``WritableFileHandleProtocol`` by making system calls to interact with the local
/// file system.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct WriteFileHandle: WritableFileHandleProtocol, _HasFileHandle, Sendable {
    public let fileHandle: FileHandle

    internal init(wrapping systemFileHandle: SystemFileHandle) {
        self.fileHandle = FileHandle(wrapping: systemFileHandle)
    }

    @discardableResult
    public func write(
        contentsOf bytes: some (Sequence<UInt8> & Sendable),
        toAbsoluteOffset offset: Int64
    ) async throws -> Int64 {
        try await self.fileHandle.systemFileHandle.write(
            contentsOf: bytes,
            toAbsoluteOffset: offset
        )
    }

    public func resize(to size: ByteCount) async throws {
        try await self.fileHandle.systemFileHandle.resize(to: size)
    }

    public func close(makeChangesVisible: Bool) async throws {
        try await self.fileHandle.systemFileHandle.close(makeChangesVisible: makeChangesVisible)
    }

    public func setTimes(
        lastAccess: FileInfo.Timespec?,
        lastDataModification: FileInfo.Timespec?
    ) async throws {
        try await self.fileHandle.systemFileHandle.setTimes(
            lastAccess: lastAccess,
            lastDataModification: lastDataModification
        )
    }
}

/// Implements ``ReadableAndWritableFileHandleProtocol`` by making system calls to interact with the
/// local file system.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct ReadWriteFileHandle: ReadableAndWritableFileHandleProtocol, _HasFileHandle, Sendable {
    public let fileHandle: FileHandle

    internal init(wrapping systemFileHandle: SystemFileHandle) {
        self.fileHandle = FileHandle(wrapping: systemFileHandle)
    }

    public func readChunk(
        fromAbsoluteOffset offset: Int64,
        length: ByteCount
    ) async throws -> ByteBuffer {
        try await self.fileHandle.systemFileHandle.readChunk(
            fromAbsoluteOffset: offset,
            length: length
        )
    }

    public func readChunks(in offset: Range<Int64>, chunkLength: ByteCount) -> FileChunks {
        self.fileHandle.systemFileHandle.readChunks(in: offset, chunkLength: chunkLength)
    }

    @discardableResult
    public func write(
        contentsOf bytes: some (Sequence<UInt8> & Sendable),
        toAbsoluteOffset offset: Int64
    ) async throws -> Int64 {
        try await self.fileHandle.systemFileHandle.write(
            contentsOf: bytes,
            toAbsoluteOffset: offset
        )
    }

    public func resize(to size: ByteCount) async throws {
        try await self.fileHandle.systemFileHandle.resize(to: size)
    }

    public func close(makeChangesVisible: Bool) async throws {
        try await self.fileHandle.systemFileHandle.close(makeChangesVisible: makeChangesVisible)
    }

    public func setTimes(
        lastAccess: FileInfo.Timespec?,
        lastDataModification: FileInfo.Timespec?
    ) async throws {
        try await self.fileHandle.systemFileHandle.setTimes(
            lastAccess: lastAccess,
            lastDataModification: lastDataModification
        )
    }
}

/// Implements ``DirectoryFileHandleProtocol`` by making system calls to interact with the local
/// file system.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct DirectoryFileHandle: DirectoryFileHandleProtocol, _HasFileHandle, Sendable {
    public let fileHandle: FileHandle

    internal init(wrapping systemFileHandle: SystemFileHandle) {
        self.fileHandle = FileHandle(wrapping: systemFileHandle)
    }

    public func listContents(recursive: Bool) -> DirectoryEntries {
        self.fileHandle.systemFileHandle.listContents(recursive: recursive)
    }

    public func openFile(
        forReadingAt path: FilePath,
        options: OpenOptions.Read
    ) async throws -> ReadFileHandle {
        let systemFileHandle = try await self.fileHandle.systemFileHandle.openFile(
            forReadingAt: path,
            options: options
        )
        return ReadFileHandle(wrapping: systemFileHandle)
    }

    public func openFile(
        forWritingAt path: FilePath,
        options: OpenOptions.Write
    ) async throws -> WriteFileHandle {
        let systemFileHandle = try await self.fileHandle.systemFileHandle.openFile(
            forWritingAt: path,
            options: options
        )
        return WriteFileHandle(wrapping: systemFileHandle)
    }

    public func openFile(
        forReadingAndWritingAt path: FilePath,
        options: OpenOptions.Write
    ) async throws -> ReadWriteFileHandle {
        let systemFileHandle = try await self.fileHandle.systemFileHandle.openFile(
            forReadingAndWritingAt: path,
            options: options
        )
        return ReadWriteFileHandle(wrapping: systemFileHandle)
    }

    public func openDirectory(
        atPath path: FilePath,
        options: OpenOptions.Directory
    ) async throws -> DirectoryFileHandle {
        let systemFileHandle = try await self.fileHandle.systemFileHandle.openDirectory(
            atPath: path,
            options: options
        )
        return DirectoryFileHandle(wrapping: systemFileHandle)
    }
}
