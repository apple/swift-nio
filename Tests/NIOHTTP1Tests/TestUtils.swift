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

// NOTE: This file intentionally duplicates the contents of
// Tests/NIOPosixTests/TestUtils.swift. The repository sometimes uses symlinks
// for cross-target test utilities; on filesystems where symlinks are not
// preserved, we inline the contents to ensure compilation.

// swift-format-ignore: AmbiguousTrailingClosureOverload

import NIOConcurrencyHelpers
import XCTest

@testable import NIOCore
@testable import NIOPosix

extension System {
    static var supportsIPv6: Bool {
        do {
            let ipv6Loopback = try SocketAddress.makeAddressResolvingHost("::1", port: 0)
            return try System.enumerateDevices().filter { $0.address == ipv6Loopback }.first != nil
        } catch {
            return false
        }
    }

    static var supportsVsockLoopback: Bool {
        #if os(Linux) || os(Android)
        guard let modules = try? String(contentsOf: URL(fileURLWithPath: "/proc/modules"), encoding: .utf8) else {
            return false
        }
        return modules.split(separator: "\n").compactMap({ $0.split(separator: " ").first }).contains("vsock_loopback")
        #else
        return false
        #endif
    }
}

func withPipe(_ body: (NIOCore.NIOFileHandle, NIOCore.NIOFileHandle) throws -> [NIOCore.NIOFileHandle]) throws {
    var fds: [Int32] = [-1, -1]
    fds.withUnsafeMutableBufferPointer { ptr in
        XCTAssertEqual(0, pipe(ptr.baseAddress!))
    }
    let readFH = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: fds[0])
    let writeFH = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: fds[1])
    var toClose: [NIOFileHandle] = [readFH, writeFH]
    var error: Error? = nil
    do {
        toClose = try body(readFH, writeFH)
    } catch let err {
        error = err
    }
    for fileHandle in toClose {
        XCTAssertNoThrow(try fileHandle.close())
    }
    if let error = error {
        throw error
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
func withPipe(
    _ body: (NIOCore.NIOFileHandle, NIOCore.NIOFileHandle) async throws -> [NIOCore.NIOFileHandle]
) async throws {
    var fds: [Int32] = [-1, -1]
    fds.withUnsafeMutableBufferPointer { ptr in
        XCTAssertEqual(0, pipe(ptr.baseAddress!))
    }
    let readFH = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: fds[0])
    let writeFH = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: fds[1])
    var toClose: [NIOFileHandle] = [readFH, writeFH]
    var error: Error? = nil
    do {
        toClose = try await body(readFH, writeFH)
    } catch let err {
        error = err
    }
    for fileHandle in toClose {
        try fileHandle.close()
    }
    if let error = error {
        throw error
    }
}

// swift-format-ignore: AmbiguousTrailingClosureOverload
func withTemporaryDirectory<T>(_ body: (String) throws -> T) rethrows -> T {
    let dir = createTemporaryDirectory()
    defer {
        try? FileManager.default.removeItem(atPath: dir)
    }
    return try body(dir)
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
func withTemporaryDirectory<T>(_ body: (String) async throws -> T) async rethrows -> T {
    let dir = createTemporaryDirectory()
    defer {
        try? FileManager.default.removeItem(atPath: dir)
    }
    return try await body(dir)
}

/// This function creates a filename that can be used for a temporary UNIX domain socket path.
///
/// If the temporary directory is too long to store a UNIX domain socket path, it will `chdir` into the temporary
/// directory and return a short-enough path. The iOS simulator is known to have too long paths.
func withTemporaryUnixDomainSocketPathName<T>(
    directory: String = temporaryDirectory,
    _ body: (String) throws -> T
) throws -> T {
    // this is racy but we're trying to create the shortest possible path so we can't add a directory...
    let (fd, path) = openTemporaryFile()
    try! Posix.close(descriptor: fd)
    try! FileManager.default.removeItem(atPath: path)

    let saveCurrentDirectory = FileManager.default.currentDirectoryPath
    let restoreSavedCWD: Bool
    let shortEnoughPath: String
    do {
        _ = try SocketAddress(unixDomainSocketPath: path)
        // this seems to be short enough for a UDS
        shortEnoughPath = path
        restoreSavedCWD = false
    } catch SocketAddressError.unixDomainSocketPathTooLong {
        _ = FileManager.default.changeCurrentDirectoryPath(
            URL(fileURLWithPath: path).deletingLastPathComponent().absoluteString
        )
        shortEnoughPath = URL(fileURLWithPath: path).lastPathComponent
        restoreSavedCWD = true
        print(
            "WARNING: Path '\(path)' could not be used as UNIX domain socket path, using chdir & '\(shortEnoughPath)'"
        )
    }
    defer {
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        if restoreSavedCWD {
            _ = FileManager.default.changeCurrentDirectoryPath(saveCurrentDirectory)
        }
    }
    return try body(shortEnoughPath)
}

func withTemporaryFile<T>(
    content: String? = nil,
    _ body: (NIOCore.NIOFileHandle, String) throws -> T
) rethrows -> T {
    let (fd, path) = openTemporaryFile()
    let fileHandle = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: fd)
    defer {
        XCTAssertNoThrow(try fileHandle.close())
        XCTAssertEqual(0, unlink(path))
    }
    if let content = content {
        try Array(content.utf8).withUnsafeBufferPointer { ptr in
            var toWrite = ptr.count
            var start = ptr.baseAddress!
            while toWrite > 0 {
                let res = try Posix.write(descriptor: fd, pointer: start, size: toWrite)
                switch res {
                case .processed(let written):
                    toWrite -= written
                    start = start + written
                case .wouldBlock:
                    XCTFail("unexpectedly got .wouldBlock from a file")
                    continue
                }
            }
            XCTAssertEqual(0, lseek(fd, 0, SEEK_SET))
        }
    }
    return try body(fileHandle, path)
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
func withTemporaryFile<T>(
    content: String? = nil,
    _ body: @escaping (NIOCore.NIOFileHandle, String) async throws -> T
) async rethrows -> T {
    let (fd, path) = openTemporaryFile()
    let fileHandle = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: fd)
    defer {
        XCTAssertNoThrow(try fileHandle.close())
        XCTAssertEqual(0, unlink(path))
    }
    if let content = content {
        try Array(content.utf8).withUnsafeBufferPointer { ptr in
            var toWrite = ptr.count
            var start = ptr.baseAddress!
            while toWrite > 0 {
                let res = try Posix.write(descriptor: fd, pointer: start, size: toWrite)
                switch res {
                case .processed(let written):
                    toWrite -= written
                    start = start + written
                case .wouldBlock:
                    XCTFail("unexpectedly got .wouldBlock from a file")
                    continue
                }
            }
            XCTAssertEqual(0, lseek(fd, 0, SEEK_SET))
        }
    }
    return try await body(fileHandle, path)
}
var temporaryDirectory: String {
    get {
        #if targetEnvironment(simulator)
        // Simulator temp directories are so long (and contain the user name) that they're not usable
        // for UNIX Domain Socket paths (which are limited to 103 bytes).
        return "/tmp"
        #else
        #if os(Linux)
        return "/tmp"
        #else
        if #available(macOS 10.12, iOS 10, tvOS 10, watchOS 3, *) {
            return FileManager.default.temporaryDirectory.path
        } else {
            return "/tmp"
        }
        #endif  // os
        #endif  // targetEnvironment
    }
}

func createTemporaryDirectory() -> String {
    let template = "\(temporaryDirectory)/.NIOTests-temp-dir_XXXXXX"

    var templateBytes = template.utf8 + [0]
    let templateBytesCount = templateBytes.count
    templateBytes.withUnsafeMutableBufferPointer { ptr in
        ptr.baseAddress!.withMemoryRebound(to: Int8.self, capacity: templateBytesCount) {
            (ptr: UnsafeMutablePointer<Int8>) in
            let ret = mkdtemp(ptr)
            XCTAssertNotNil(ret)
        }
    }
    templateBytes.removeLast()
    return String(decoding: templateBytes, as: Unicode.UTF8.self)
}

func openTemporaryFile() -> (CInt, String) {
    let template = "\(temporaryDirectory)/nio_XXXXXX"
    var templateBytes = template.utf8 + [0]
    let templateBytesCount = templateBytes.count
    let fd = templateBytes.withUnsafeMutableBufferPointer { ptr in
        ptr.baseAddress!.withMemoryRebound(to: Int8.self, capacity: templateBytesCount) {
            (ptr: UnsafeMutablePointer<Int8>) in
            mkstemp(ptr)
        }
    }
    templateBytes.removeLast()
    return (fd, String(decoding: templateBytes, as: Unicode.UTF8.self))
}

extension Channel {
    func syncCloseAcceptingAlreadyClosed() throws {
        do {
            try self.close().wait()
        } catch ChannelError.alreadyClosed {
            // we're happy with this one
        } catch let e {
            throw e
        }
    }
}

final class ByteCountingHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    private let numBytes: Int
    private let promise: EventLoopPromise<ByteBuffer>
    private var buffer: ByteBuffer!

    init(numBytes: Int, promise: EventLoopPromise<ByteBuffer>) {
        self.numBytes = numBytes
        self.promise = promise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        buffer = context.channel.allocator.buffer(capacity: numBytes)
        if self.numBytes == 0 {
            self.promise.succeed(buffer)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var currentBuffer = Self.unwrapInboundIn(data)
        buffer.writeBuffer(&currentBuffer)

        if buffer.readableBytes == numBytes {
            promise.succeed(buffer)
        }
    }

    func assertReceived(buffer: ByteBuffer) throws {
        let received = try promise.futureResult.wait()
        XCTAssertEqual(buffer, received)
    }
}

final class NonAcceptingServerSocket: ServerSocket {
    private var errors: [Int32]

    init(errors: [Int32]) throws {
        // Reverse so it's cheaper to remove errors.
        self.errors = errors.reversed()
        try super.init(protocolFamily: .inet, setNonBlocking: true)
    }

    override func accept(setNonBlocking: Bool) throws -> Socket? {
        if let err = self.errors.last {
            _ = self.errors.removeLast()
            throw IOError(errnoCode: err, reason: "accept")
        }
        return nil
    }
}

func assertSetGetOptionOnOpenAndClosed<Option: ChannelOption>(
    channel: Channel,
    option: Option,
    value: Option.Value
) throws {
    _ = try channel.setOption(option, value: value).wait()
    _ = try channel.getOption(option).wait()
    try channel.close().wait()
    try channel.closeFuture.wait()

    do {
        _ = try channel.setOption(option, value: value).wait()
        // We're okay with no error
    } catch let err as ChannelError where err == .ioOnClosedChannel {
        // as well as already closed channels.
    }

    do {
        _ = try channel.getOption(option).wait()
        // We're okay with no error
    } catch let err as ChannelError where err == .ioOnClosedChannel {
        // as well as already closed channels.
    }
}

func assertNoThrowWithValue<T>(
    _ body: @autoclosure () throws -> T,
    defaultValue: T? = nil,
    message: String? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    do {
        return try body()
    } catch {
        XCTFail("\(message.map { $0 + ": " } ?? "")unexpected error \(error) thrown", file: (file), line: line)
        if let defaultValue = defaultValue {
            return defaultValue
        } else {
            throw error
        }
    }
}

func resolverDebugInformation(
    eventLoop: EventLoop,
    host: String,
    previouslyReceivedResult: SocketAddress
) throws -> String {
    func printSocketAddress(_ socketAddress: SocketAddress) -> String {
        switch socketAddress {
        case .unixDomainSocket(_):
            return "uds"
        case .v4(let sa):
            return __testOnly_addressDescription(sa.address)
        case .v6(let sa):
            return __testOnly_addressDescription(sa.address)
        }
    }
    let res = GetaddrinfoResolver(loop: eventLoop, aiSocktype: .stream, aiProtocol: .tcp)
    let ipv6Results = try assertNoThrowWithValue(res.initiateAAAAQuery(host: host, port: 0).wait()).map(
        printSocketAddress
    )
    let ipv4Results = try assertNoThrowWithValue(res.initiateAQuery(host: host, port: 0).wait()).map(printSocketAddress)

    return """
        when trying to resolve '\(host)' we've got the following results:
        - previous try: \(printSocketAddress(previouslyReceivedResult))
        - all results:
        IPv4: \(ipv4Results)
        IPv6: \(ipv6Results)
        """
}
