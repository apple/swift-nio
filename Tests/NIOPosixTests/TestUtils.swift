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

func assert(
    _ condition: @autoclosure () -> Bool,
    within time: TimeAmount,
    testInterval: TimeAmount? = nil,
    _ message: String = "condition not satisfied in time",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let testInterval = testInterval ?? TimeAmount.nanoseconds(time.nanoseconds / 5)
    let endTime = NIODeadline.now() + time

    repeat {
        if condition() { return }
        usleep(UInt32(testInterval.nanoseconds / 1000))
    } while NIODeadline.now() < endTime

    if !condition() {
        XCTFail(message, file: (file), line: line)
    }
}

func getBoolSocketOption(
    channel: Channel,
    level: NIOBSDSocket.OptionLevel,
    name: NIOBSDSocket.Option,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> Bool {
    try assertNoThrowWithValue(
        channel.getOption(ChannelOptions.Types.SocketOption(level: level, name: name)),
        file: (file),
        line: line
    ).wait() != 0
}

func assertSuccess<Value>(_ result: Result<Value, Error>, file: StaticString = #filePath, line: UInt = #line) {
    guard case .success = result else { return XCTFail("Expected result to be successful", file: (file), line: line) }
}

func assertFailure<Value>(_ result: Result<Value, Error>, file: StaticString = #filePath, line: UInt = #line) {
    guard case .failure = result else { return XCTFail("Expected result to be a failure", file: (file), line: line) }
}

/// Fulfills the promise when the respective event is first received.
///
/// - Note: Once this is used more widely and shows value, we might want to put it into `NIOTestUtils`.
final class FulfillOnFirstEventHandler: ChannelDuplexHandler, Sendable {
    typealias InboundIn = Any
    typealias OutboundIn = Any

    struct ExpectedEventMissing: Error {}

    private let channelRegisteredPromise: EventLoopPromise<Void>?
    private let channelUnregisteredPromise: EventLoopPromise<Void>?
    private let channelActivePromise: EventLoopPromise<Void>?
    private let channelInactivePromise: EventLoopPromise<Void>?
    private let channelReadPromise: EventLoopPromise<Void>?
    private let channelReadCompletePromise: EventLoopPromise<Void>?
    private let channelWritabilityChangedPromise: EventLoopPromise<Void>?
    private let userInboundEventTriggeredPromise: EventLoopPromise<Void>?
    private let errorCaughtPromise: EventLoopPromise<Void>?
    private let registerPromise: EventLoopPromise<Void>?
    private let bindPromise: EventLoopPromise<Void>?
    private let connectPromise: EventLoopPromise<Void>?
    private let writePromise: EventLoopPromise<Void>?
    private let flushPromise: EventLoopPromise<Void>?
    private let readPromise: EventLoopPromise<Void>?
    private let closePromise: EventLoopPromise<Void>?
    private let triggerUserOutboundEventPromise: EventLoopPromise<Void>?

    init(
        channelRegisteredPromise: EventLoopPromise<Void>? = nil,
        channelUnregisteredPromise: EventLoopPromise<Void>? = nil,
        channelActivePromise: EventLoopPromise<Void>? = nil,
        channelInactivePromise: EventLoopPromise<Void>? = nil,
        channelReadPromise: EventLoopPromise<Void>? = nil,
        channelReadCompletePromise: EventLoopPromise<Void>? = nil,
        channelWritabilityChangedPromise: EventLoopPromise<Void>? = nil,
        userInboundEventTriggeredPromise: EventLoopPromise<Void>? = nil,
        errorCaughtPromise: EventLoopPromise<Void>? = nil,
        registerPromise: EventLoopPromise<Void>? = nil,
        bindPromise: EventLoopPromise<Void>? = nil,
        connectPromise: EventLoopPromise<Void>? = nil,
        writePromise: EventLoopPromise<Void>? = nil,
        flushPromise: EventLoopPromise<Void>? = nil,
        readPromise: EventLoopPromise<Void>? = nil,
        closePromise: EventLoopPromise<Void>? = nil,
        triggerUserOutboundEventPromise: EventLoopPromise<Void>? = nil
    ) {
        self.channelRegisteredPromise = channelRegisteredPromise
        self.channelUnregisteredPromise = channelUnregisteredPromise
        self.channelActivePromise = channelActivePromise
        self.channelInactivePromise = channelInactivePromise
        self.channelReadPromise = channelReadPromise
        self.channelReadCompletePromise = channelReadCompletePromise
        self.channelWritabilityChangedPromise = channelWritabilityChangedPromise
        self.userInboundEventTriggeredPromise = userInboundEventTriggeredPromise
        self.errorCaughtPromise = errorCaughtPromise
        self.registerPromise = registerPromise
        self.bindPromise = bindPromise
        self.connectPromise = connectPromise
        self.writePromise = writePromise
        self.flushPromise = flushPromise
        self.readPromise = readPromise
        self.closePromise = closePromise
        self.triggerUserOutboundEventPromise = triggerUserOutboundEventPromise
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.channelRegisteredPromise?.fail(ExpectedEventMissing())
        self.channelUnregisteredPromise?.fail(ExpectedEventMissing())
        self.channelActivePromise?.fail(ExpectedEventMissing())
        self.channelInactivePromise?.fail(ExpectedEventMissing())
        self.channelReadPromise?.fail(ExpectedEventMissing())
        self.channelReadCompletePromise?.fail(ExpectedEventMissing())
        self.channelWritabilityChangedPromise?.fail(ExpectedEventMissing())
        self.userInboundEventTriggeredPromise?.fail(ExpectedEventMissing())
        self.errorCaughtPromise?.fail(ExpectedEventMissing())
        self.registerPromise?.fail(ExpectedEventMissing())
        self.bindPromise?.fail(ExpectedEventMissing())
        self.connectPromise?.fail(ExpectedEventMissing())
        self.writePromise?.fail(ExpectedEventMissing())
        self.flushPromise?.fail(ExpectedEventMissing())
        self.readPromise?.fail(ExpectedEventMissing())
        self.closePromise?.fail(ExpectedEventMissing())
        self.triggerUserOutboundEventPromise?.fail(ExpectedEventMissing())
    }

    func channelRegistered(context: ChannelHandlerContext) {
        self.channelRegisteredPromise?.succeed(())
        context.fireChannelRegistered()
    }

    func channelUnregistered(context: ChannelHandlerContext) {
        self.channelUnregisteredPromise?.succeed(())
        context.fireChannelUnregistered()
    }

    func channelActive(context: ChannelHandlerContext) {
        self.channelActivePromise?.succeed(())
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.channelInactivePromise?.succeed(())
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.channelReadPromise?.succeed(())
        context.fireChannelRead(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        self.channelReadCompletePromise?.succeed(())
        context.fireChannelReadComplete()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        self.channelWritabilityChangedPromise?.succeed(())
        context.fireChannelWritabilityChanged()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        self.userInboundEventTriggeredPromise?.succeed(())
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.errorCaughtPromise?.succeed(())
        context.fireErrorCaught(error)
    }

    func register(context: ChannelHandlerContext, promise: EventLoopPromise<Void>?) {
        self.registerPromise?.succeed(())
        context.register(promise: promise)
    }

    func bind(context: ChannelHandlerContext, to: SocketAddress, promise: EventLoopPromise<Void>?) {
        self.bindPromise?.succeed(())
        context.bind(to: to, promise: promise)
    }

    func connect(context: ChannelHandlerContext, to: SocketAddress, promise: EventLoopPromise<Void>?) {
        self.connectPromise?.succeed(())
        context.connect(to: to, promise: promise)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        self.writePromise?.succeed(())
        context.write(data, promise: promise)
    }

    func flush(context: ChannelHandlerContext) {
        self.flushPromise?.succeed(())
        context.flush()
    }

    func read(context: ChannelHandlerContext) {
        self.readPromise?.succeed(())
        context.read()
    }

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        self.closePromise?.succeed(())
        context.close(mode: mode, promise: promise)
    }

    func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        self.triggerUserOutboundEventPromise?.succeed(())
        context.triggerUserOutboundEvent(event, promise: promise)
    }
}

func forEachActiveChannelType<T>(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: @escaping (Channel) throws -> T
) throws -> [T] {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer {
        XCTAssertNoThrow(try group.syncShutdownGracefully())
    }
    let channelEL = group.next()

    let lock = NIOLock()
    var ret: [T] = []
    _ = try forEachCrossConnectedStreamChannelPair(file: (file), line: line) {
        (chan1: Channel, chan2: Channel) throws -> Void in
        var innerRet: [T] = [try body(chan1)]
        if let parent = chan1.parent {
            innerRet.append(try body(parent))
        }
        lock.withLock {
            ret.append(contentsOf: innerRet)
        }
    }

    // UDP
    let udpChannel = DatagramBootstrap(group: channelEL)
        .channelInitializer { channel in
            XCTAssert(channel.eventLoop.inEventLoop)
            return channelEL.makeSucceededFuture(())
        }
        .bind(host: "127.0.0.1", port: 0)
    defer {
        XCTAssertNoThrow(try udpChannel.wait().syncCloseAcceptingAlreadyClosed())
    }

    return try lock.withLock {
        ret.append(try body(udpChannel.wait()))
        return ret
    }
}

func withTCPServerChannel<R>(
    bindTarget: SocketAddress? = nil,
    group: EventLoopGroup,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: (Channel) throws -> R
) throws -> R {
    let server = try ServerBootstrap(group: group)
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        .bind(to: bindTarget ?? .init(ipAddress: "127.0.0.1", port: 0))
        .wait()
    do {
        let result = try body(server)
        try server.close().wait()
        return result
    } catch {
        try? server.close().wait()
        throw error
    }
}

func withCrossConnectedSockAddrChannels<R>(
    bindTarget: SocketAddress,
    forceSeparateEventLoops: Bool = false,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: (Channel, Channel) throws -> R
) throws -> R {
    let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer {
        XCTAssertNoThrow(try serverGroup.syncShutdownGracefully())
    }
    let clientGroup: MultiThreadedEventLoopGroup
    if forceSeparateEventLoops {
        clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    } else {
        clientGroup = serverGroup
    }
    defer {
        // this may fail if clientGroup === serverGroup
        try? clientGroup.syncShutdownGracefully()
    }
    let serverChannelEL = serverGroup.next()
    let clientChannelEL = clientGroup.next()

    let tcpAcceptedChannel = serverChannelEL.makePromise(of: Channel.self)
    let tcpServerChannel = try assertNoThrowWithValue(
        ServerBootstrap(group: serverChannelEL)
            .childChannelInitializer { channel in
                let accepted = channel.eventLoop.makePromise(of: Void.self)
                accepted.futureResult.map {
                    channel
                }.cascade(to: tcpAcceptedChannel)
                return channel.pipeline.addHandler(FulfillOnFirstEventHandler(channelActivePromise: accepted))
            }
            .bind(to: bindTarget)
            .wait(),
        file: (file),
        line: line
    )
    defer {
        XCTAssertNoThrow(try tcpServerChannel.syncCloseAcceptingAlreadyClosed())
    }

    let tcpClientChannel = try assertNoThrowWithValue(
        ClientBootstrap(group: clientChannelEL)
            .channelInitializer { channel in
                XCTAssert(channel.eventLoop.inEventLoop)
                return channel.eventLoop.makeSucceededFuture(())
            }
            .connect(to: tcpServerChannel.localAddress!)
            .wait()
    )
    defer {
        XCTAssertNoThrow(try tcpClientChannel.syncCloseAcceptingAlreadyClosed())
    }

    return try body(try tcpAcceptedChannel.futureResult.wait(), tcpClientChannel)
}

func withCrossConnectedTCPChannels<R>(
    forceSeparateEventLoops: Bool = false,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: (Channel, Channel) throws -> R
) throws -> R {
    try withCrossConnectedSockAddrChannels(
        bindTarget: .init(ipAddress: "127.0.0.1", port: 0),
        forceSeparateEventLoops: forceSeparateEventLoops,
        body
    )
}

func withCrossConnectedUnixDomainSocketChannels<R>(
    forceSeparateEventLoops: Bool = false,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: (Channel, Channel) throws -> R
) throws -> R {
    try withTemporaryDirectory { tempDir in
        let bindTarget = try SocketAddress(unixDomainSocketPath: tempDir + "/s")
        return try withCrossConnectedSockAddrChannels(
            bindTarget: bindTarget,
            forceSeparateEventLoops: forceSeparateEventLoops,
            body
        )
    }
}

func withCrossConnectedPipeChannels<R>(
    forceSeparateEventLoops: Bool = false,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: (Channel, Channel) throws -> R
) throws -> R {
    let channel1Group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer {
        XCTAssertNoThrow(try channel1Group.syncShutdownGracefully(), file: (file), line: line)
    }
    let channel2Group: MultiThreadedEventLoopGroup
    if forceSeparateEventLoops {
        channel2Group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    } else {
        channel2Group = channel1Group
    }
    defer {
        // may fail if pipe1Group == pipe2Group
        try? channel2Group.syncShutdownGracefully()
    }

    var result: R? = nil

    XCTAssertNoThrow(
        try withPipe { pipe1Read, pipe1Write -> [NIOFileHandle] in
            try withPipe { pipe2Read, pipe2Write -> [NIOFileHandle] in
                try pipe1Read.withUnsafeFileDescriptor { pipe1Read in
                    try pipe1Write.withUnsafeFileDescriptor { pipe1Write in
                        try pipe2Read.withUnsafeFileDescriptor { pipe2Read in
                            try pipe2Write.withUnsafeFileDescriptor { pipe2Write in
                                let channel1 = try NIOPipeBootstrap(group: channel1Group)
                                    .takingOwnershipOfDescriptors(input: pipe1Read, output: pipe2Write)
                                    .wait()
                                defer {
                                    XCTAssertNoThrow(try channel1.syncCloseAcceptingAlreadyClosed())
                                }
                                let channel2 = try NIOPipeBootstrap(group: channel2Group)
                                    .takingOwnershipOfDescriptors(input: pipe2Read, output: pipe1Write)
                                    .wait()
                                defer {
                                    XCTAssertNoThrow(try channel2.syncCloseAcceptingAlreadyClosed())
                                }
                                result = try body(channel1, channel2)
                            }
                        }
                    }
                }
                XCTAssertNoThrow(try pipe1Read.takeDescriptorOwnership(), file: (file), line: line)
                XCTAssertNoThrow(try pipe1Write.takeDescriptorOwnership(), file: (file), line: line)
                XCTAssertNoThrow(try pipe2Read.takeDescriptorOwnership(), file: (file), line: line)
                XCTAssertNoThrow(try pipe2Write.takeDescriptorOwnership(), file: (file), line: line)
                return []
            }
            return []  // the channels are closing the pipes
        },
        file: (file),
        line: line
    )
    return result!
}

func forEachCrossConnectedStreamChannelPair<R>(
    forceSeparateEventLoops: Bool = false,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: (Channel, Channel) throws -> R
) throws -> [R] {
    let r1 = try withCrossConnectedTCPChannels(forceSeparateEventLoops: forceSeparateEventLoops, body)
    let r2 = try withCrossConnectedPipeChannels(forceSeparateEventLoops: forceSeparateEventLoops, body)
    let r3 = try withCrossConnectedUnixDomainSocketChannels(forceSeparateEventLoops: forceSeparateEventLoops, body)
    return [r1, r2, r3]
}

extension EventLoopFuture {
    var isFulfilled: Bool {
        if self.eventLoop.inEventLoop {
            // Easy, we're on the EventLoop. Let's just use our knowledge that we run completed future callbacks
            // immediately.
            var fulfilled = false
            self.assumeIsolated().whenComplete { _ in
                fulfilled = true
            }
            return fulfilled
        } else {
            let fulfilledBox = NIOLockedValueBox(false)
            let group = DispatchGroup()

            group.enter()
            self.eventLoop.execute {
                let isFulfilled = self.isFulfilled  // This will now enter the above branch.
                fulfilledBox.withLockedValue {
                    $0 = isFulfilled
                }
                group.leave()
            }
            group.wait()  // this is very nasty but this is for tests only, so...
            return fulfilledBox.withLockedValue { $0 }
        }
    }
}
