//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// This file contains a syscall abstraction layer (SAL) which hooks the Selector and the Socket in a way that we can
// play the kernel whilst NIO thinks it's running on a real OS.

import NIOCore
@testable import NIOPosix
import NIOConcurrencyHelpers
import XCTest

internal enum SAL {
    fileprivate static let defaultTimeout: Double = 5
    private static let debugTests: Bool = false
    fileprivate static func printIfDebug(_ item: Any) {
        if debugTests {
            print(item)
        }
    }
}

final class LockedBox<T> {
    struct TimeoutError: Error {
        var description: String
        init(_ description: String) {
            self.description = description
        }
    }
    struct ExpectedEmptyBox: Error {}

    private let condition = ConditionLock(value: 0)
    private let description: String
    private let didSet: (T?) -> Void
    private var _value: T? {
        didSet {
            self.didSet(self._value)
        }
    }

    init(_ value: T? = nil,
         description: String? = nil,
         file: StaticString = #filePath,
         line: UInt = #line,
         didSet: @escaping (T?) -> Void = { _ in }) {
        self._value = value
        self.didSet = didSet
        self.description = description ?? "\(file):\(line)"
    }

    internal var value: T? {
        get {
            self.condition.lock()
            defer {
                self.condition.unlock()
            }
            return self._value
        }

        set {
            self.condition.lock()
            if let value = newValue {
                self._value = value
                self.condition.unlock(withValue: 1)
            } else {
                self._value = nil
                self.condition.unlock(withValue: 0)
            }
        }
    }

    func waitForEmptyAndSet(_ value: T) throws {
        if self.condition.lock(whenValue: 0, timeoutSeconds: SAL.defaultTimeout) {
            defer {
                self.condition.unlock(withValue: 1)
            }
            self._value = value
        } else {
            throw TimeoutError(self.description)
        }
    }

    func takeValue() throws -> T {
        if self.condition.lock(whenValue: 1, timeoutSeconds: SAL.defaultTimeout) {
            defer {
                self.condition.unlock(withValue: 0)
            }
            let value = self._value!
            self._value = nil
            return value
        } else {
            throw TimeoutError(self.description)
        }
    }

    func waitForValue() throws -> T {
        if self.condition.lock(whenValue: 1, timeoutSeconds: SAL.defaultTimeout) {
            defer {
                self.condition.unlock(withValue: 1)
            }
            return self._value!
        } else {
            throw TimeoutError(self.description)
        }
    }
}

extension LockedBox where T == UserToKernel {
    func assertParkedRightNow(file: StaticString = #filePath, line: UInt = #line) throws {
        SAL.printIfDebug("\(#function)")
        let syscall = try self.waitForValue()
        if case .whenReady(.block) = syscall {
            return
        } else {
            XCTFail("unexpected syscall \(syscall)", file: (file), line: line)
        }
    }
}

enum UserToKernel {
    case localAddress
    case remoteAddress
    case connect(SocketAddress)
    case read(Int)
    case close(CInt)
    case register(Selectable, SelectorEventSet, NIORegistration)
    case reregister(Selectable, SelectorEventSet)
    case deregister(Selectable)
    case whenReady(SelectorStrategy)
    case disableSIGPIPE(CInt)
    case write(CInt, ByteBuffer)
    case writev(CInt, [ByteBuffer])
    case bind(SocketAddress)
    case setOption(NIOBSDSocket.OptionLevel, NIOBSDSocket.Option, Any)
    case listen(CInt, CInt)
    case accept(CInt, Bool)
}

enum KernelToUser {
    case returnSocketAddress(SocketAddress)
    case returnBool(Bool)
    case returnBytes(ByteBuffer)
    case returnVoid
    case returnSelectorEvent(SelectorEvent<NIORegistration>?)
    case returnIOResultInt(IOResult<Int>)
    case returnSocket(Socket?)
    case error(Error)
}

struct UnexpectedKernelReturn: Error {
    private var ret: KernelToUser

    init(_ ret: KernelToUser) {
        self.ret = ret
    }
}

struct UnexpectedSyscall: Error {
    private var syscall: UserToKernel

    init(_ syscall: UserToKernel) {
        self.syscall = syscall
    }
}

private protocol UserKernelInterface {
    var userToKernel: LockedBox<UserToKernel> { get }
    var kernelToUser: LockedBox<KernelToUser> { get }
}

extension UserKernelInterface {
    fileprivate func waitForKernelReturn() throws -> KernelToUser {
        let value = try self.kernelToUser.takeValue()
        if case .error(let error) = value {
            throw error
        } else {
            return value
        }
    }
}

internal class HookedSelector: NIOPosix.Selector<NIORegistration>, UserKernelInterface {
    fileprivate let userToKernel: LockedBox<UserToKernel>
    fileprivate let kernelToUser: LockedBox<KernelToUser>
    fileprivate let wakeups: LockedBox<()>

    init(userToKernel: LockedBox<UserToKernel>, kernelToUser: LockedBox<KernelToUser>, wakeups: LockedBox<()>) throws {
        self.userToKernel = userToKernel
        self.kernelToUser = kernelToUser
        self.wakeups = wakeups
        try super.init()
        self.lifecycleState = .open
    }

    override func register<S: Selectable>(selectable: S,
                                          interested: SelectorEventSet,
                                          makeRegistration: (SelectorEventSet, SelectorRegistrationID) -> NIORegistration) throws {
        try self.userToKernel.waitForEmptyAndSet(.register(selectable, interested, makeRegistration(interested,
                                                                                                    .initialRegistrationID)))
        let ret = try self.waitForKernelReturn()
        if case .returnVoid = ret {
            return
        } else {
            throw UnexpectedKernelReturn(ret)
        }
    }

    override func reregister<S: Selectable>(selectable: S, interested: SelectorEventSet) throws {
        try self.userToKernel.waitForEmptyAndSet(.reregister(selectable, interested))
        let ret = try self.waitForKernelReturn()
        if case .returnVoid = ret {
            return
        } else {
            throw UnexpectedKernelReturn(ret)
        }
    }

    override func whenReady(strategy: SelectorStrategy, onLoopBegin loopStart: () -> Void,  _ body: (SelectorEvent<NIORegistration>) throws -> Void) throws -> Void {
        try self.userToKernel.waitForEmptyAndSet(.whenReady(strategy))
        let ret = try self.waitForKernelReturn()
        if case .returnSelectorEvent(let event) = ret {
            loopStart()
            if let event = event {
                try body(event)
            }
            return
        } else {
            throw UnexpectedKernelReturn(ret)
        }
    }

    override func deregister<S: Selectable>(selectable: S) throws {
        try self.userToKernel.waitForEmptyAndSet(.deregister(selectable))
        let ret = try self.waitForKernelReturn()
        if case .returnVoid = ret {
            return
        } else {
            throw UnexpectedKernelReturn(ret)
        }
    }

    override func wakeup() throws {
        SAL.printIfDebug("WAKEUP")
        try self.wakeups.waitForEmptyAndSet(())
    }
}

class HookedServerSocket: ServerSocket, UserKernelInterface {
    fileprivate let userToKernel: LockedBox<UserToKernel>
    fileprivate let kernelToUser: LockedBox<KernelToUser>

    init(userToKernel: LockedBox<UserToKernel>, kernelToUser: LockedBox<KernelToUser>, socket: NIOBSDSocket.Handle) throws {
        self.userToKernel = userToKernel
        self.kernelToUser = kernelToUser
        try super.init(socket: socket)
    }

    override func ignoreSIGPIPE() throws {
        try self.withUnsafeHandle { fd in
            try self.userToKernel.waitForEmptyAndSet(.disableSIGPIPE(fd))
            let ret = try self.waitForKernelReturn()
            if case .returnVoid = ret {
                return
            } else {
                throw UnexpectedKernelReturn(ret)
            }
        }
    }

    override func localAddress() throws -> SocketAddress {
        try self.userToKernel.waitForEmptyAndSet(.localAddress)
        let ret = try self.waitForKernelReturn()
        if case .returnSocketAddress(let address) = ret {
            return address
        } else {
            throw UnexpectedKernelReturn(ret)
        }
    }

    override func remoteAddress() throws -> SocketAddress {
        try self.userToKernel.waitForEmptyAndSet(.remoteAddress)
        let ret = try self.waitForKernelReturn()
        if case .returnSocketAddress(let address) = ret {
            return address
        } else {
            throw UnexpectedKernelReturn(ret)
        }
    }

    override func bind(to address: SocketAddress) throws {
        try self.userToKernel.waitForEmptyAndSet(.bind(address))
        let ret = try self.waitForKernelReturn()
        if case .returnVoid = ret {
            return
        } else {
            throw UnexpectedKernelReturn(ret)
        }
    }

    override func listen(backlog: Int32 = 128) throws {
        try self.withUnsafeHandle { fd in
            try self.userToKernel.waitForEmptyAndSet(.listen(fd, backlog))
            let ret = try self.waitForKernelReturn()
            if case .returnVoid = ret {
                return
            } else {
                throw UnexpectedKernelReturn(ret)
            }
        }
    }

    override func accept(setNonBlocking: Bool = false) throws -> Socket? {
        try self.withUnsafeHandle { fd in
            try self.userToKernel.waitForEmptyAndSet(.accept(fd, setNonBlocking))
            let ret = try self.waitForKernelReturn()
            switch ret {
            case .returnSocket(let socket):
                return socket
            case .error(let error):
                throw error
            default:
                throw UnexpectedKernelReturn(ret)
            }
        }
    }

    override func close() throws {
        let fd = try self.takeDescriptorOwnership()

        try self.userToKernel.waitForEmptyAndSet(.close(fd))
        let ret = try self.waitForKernelReturn()
        if case .returnVoid = ret {
            return
        } else {
            throw UnexpectedKernelReturn(ret)
        }
    }
}


class HookedSocket: Socket, UserKernelInterface {
    fileprivate let userToKernel: LockedBox<UserToKernel>
    fileprivate let kernelToUser: LockedBox<KernelToUser>

    init(userToKernel: LockedBox<UserToKernel>, kernelToUser: LockedBox<KernelToUser>, socket: NIOBSDSocket.Handle) throws {
        self.userToKernel = userToKernel
        self.kernelToUser = kernelToUser
        try super.init(socket: socket)
    }

    override func ignoreSIGPIPE() throws {
        try self.withUnsafeHandle { fd in
            try self.userToKernel.waitForEmptyAndSet(.disableSIGPIPE(fd))
            let ret = try self.waitForKernelReturn()
            if case .returnVoid = ret {
                return
            } else {
                throw UnexpectedKernelReturn(ret)
            }
        }
    }

    override func localAddress() throws -> SocketAddress {
        try self.userToKernel.waitForEmptyAndSet(.localAddress)
        let ret = try self.waitForKernelReturn()
        if case .returnSocketAddress(let address) = ret {
            return address
        } else {
            throw UnexpectedKernelReturn(ret)
        }
    }

    override func remoteAddress() throws -> SocketAddress {
        try self.userToKernel.waitForEmptyAndSet(.remoteAddress)
        let ret = try self.waitForKernelReturn()
        if case .returnSocketAddress(let address) = ret {
            return address
        } else {
            throw UnexpectedKernelReturn(ret)
        }
    }

    override func connect(to address: SocketAddress) throws -> Bool {
        try self.userToKernel.waitForEmptyAndSet(.connect(address))
        let ret = try self.waitForKernelReturn()
        if case .returnBool(let success) = ret {
            return success
        } else {
            throw UnexpectedKernelReturn(ret)
        }
    }

    override func read(pointer: UnsafeMutableRawBufferPointer) throws -> IOResult<Int> {
        try self.userToKernel.waitForEmptyAndSet(.read(pointer.count))
        let ret = try self.waitForKernelReturn()
        if case .returnBytes(let buffer) = ret {
            assert(buffer.readableBytes <= pointer.count)
            pointer.copyBytes(from: buffer.readableBytesView)
            return .processed(buffer.readableBytes)
        } else {
            throw UnexpectedKernelReturn(ret)
        }
    }

    override func write(pointer: UnsafeRawBufferPointer) throws -> IOResult<Int> {
        return try self.withUnsafeHandle { fd in
            var buffer = ByteBufferAllocator().buffer(capacity: pointer.count)
            buffer.writeBytes(pointer)
            try self.userToKernel.waitForEmptyAndSet(.write(fd, buffer))
            let ret = try self.waitForKernelReturn()
            if case .returnIOResultInt(let result) = ret {
                return result
            } else {
                throw UnexpectedKernelReturn(ret)
            }
        }
    }

    override func writev(iovecs: UnsafeBufferPointer<IOVector>) throws -> IOResult<Int> {
        return try self.withUnsafeHandle { fd in
            let buffers = iovecs.map { iovec -> ByteBuffer in
                #if os(Android)
                var buffer = ByteBufferAllocator().buffer(capacity: Int(iovec.iov_len))
                buffer.writeBytes(UnsafeRawBufferPointer(start: iovec.iov_base, count: Int(iovec.iov_len)))
                #else
                var buffer = ByteBufferAllocator().buffer(capacity: iovec.iov_len)
                buffer.writeBytes(UnsafeRawBufferPointer(start: iovec.iov_base, count: iovec.iov_len))
                #endif
                return buffer
            }

            try self.userToKernel.waitForEmptyAndSet(.writev(fd, buffers))
            let ret = try self.waitForKernelReturn()
            if case .returnIOResultInt(let result) = ret {
                return result
            } else {
                throw UnexpectedKernelReturn(ret)
            }
        }
    }

    override func close() throws {
        let fd = try self.takeDescriptorOwnership()

        try self.userToKernel.waitForEmptyAndSet(.close(fd))
        let ret = try self.waitForKernelReturn()
        if case .returnVoid = ret {
            return
        } else {
            throw UnexpectedKernelReturn(ret)
        }
    }

    override func setOption<T>(level: NIOBSDSocket.OptionLevel, name: NIOBSDSocket.Option, value: T) throws {
        try self.userToKernel.waitForEmptyAndSet(.setOption(level, name, value))
        let ret = try self.waitForKernelReturn()
        if case .returnVoid = ret {
            return
        } else {
            throw UnexpectedKernelReturn(ret)
        }
    }

    override func bind(to address: SocketAddress) throws {
        try self.userToKernel.waitForEmptyAndSet(.bind(address))
        let ret = try self.waitForKernelReturn()
        if case .returnVoid = ret {
            return
        } else {
            throw UnexpectedKernelReturn(ret)
        }
    }
}

extension HookedSelector {
    func assertSyscallAndReturn(_ result: KernelToUser,
                                file: StaticString = #filePath,
                                line: UInt = #line,
                                matcher: (UserToKernel) throws -> Bool) throws {
        let syscall = try self.userToKernel.takeValue()
        if try matcher(syscall) {
            try self.kernelToUser.waitForEmptyAndSet(result)
        } else {
            XCTFail("unexpected syscall \(syscall)", file: (file), line: line)
            throw UnexpectedSyscall(syscall)
        }
    }

    /// This function will wait for an event loop wakeup until it unblocks. If the event loop
    /// is currently executing then it will not be woken: as a result, consider using
    /// `assertParkedRightNow` before the event that you want to trigger the wakeup, and before calling
    /// this code.
    func assertWakeup(file: StaticString = #filePath, line: UInt = #line) throws {
        SAL.printIfDebug("\(#function)")
        try self.wakeups.takeValue()
        try self.assertSyscallAndReturn(.returnSelectorEvent(nil), file: (file), line: line) { syscall in
            if case .whenReady(.block) = syscall {
                return true
            } else {
                return false
            }
        }
    }

    func assertParkedRightNow(file: StaticString = #filePath, line: UInt = #line) throws {
        try self.userToKernel.assertParkedRightNow(file: file, line: line)
    }
}

extension EventLoop {
    internal func runSAL<T>(syscallAssertions: () throws -> Void = {},
                            file: StaticString = #filePath,
                            line: UInt = #line,
                            _ body: @escaping () throws -> T) throws -> T {
        let hookedSelector = ((self as! SelectableEventLoop)._selector as! HookedSelector)
        let box = LockedBox<Result<T, Error>>()

        // To prevent races between the test driver thread (this thread) and the EventLoop (another thread), we need
        // to wait for the EventLoop to finish its tick and park itself. That makes sure both threads are synchronised
        // so we know exactly what the EventLoop thread is currently up to (nothing at all, waiting for a wakeup).
        try hookedSelector.userToKernel.assertParkedRightNow()

        self.execute {
            do {
                try box.waitForEmptyAndSet(.init(catching: body))
            } catch {
                box.value = .failure(error)
            }
        }
        try hookedSelector.assertWakeup(file: (file), line: line)
        try syscallAssertions()

        // Here as well, we need to synchronise and wait for the EventLoop to finish running its tick.
        try hookedSelector.userToKernel.assertParkedRightNow()
        return try box.takeValue().get()
    }
}

extension EventLoopFuture {
    /// This works like `EventLoopFuture.wait()` but can be used together with the SAL.
    ///
    /// Using a plain `EventLoopFuture.wait()` together with the SAL would require you to spin the `EventLoop` manually
    /// which is error prone and hard.
    internal func salWait() throws -> Value {
        let box = LockedBox<Result<Value, Error>>()

        XCTAssertNoThrow(try self.eventLoop.runSAL() {
            self.whenComplete { value in
                // We can bang this because the LockedBox is empty so it'll immediately succeed.
                try! box.waitForEmptyAndSet(value)
            }
        })
        return try box.waitForValue().get()
    }
}

protocol SALTest: AnyObject {
    var group: MultiThreadedEventLoopGroup! { get set }
    var wakeups: LockedBox<()>! { get set }
    var userToKernelBox: LockedBox<UserToKernel>! { get set }
    var kernelToUserBox: LockedBox<KernelToUser>! { get set }
}

extension SALTest {
    private var selector: HookedSelector {
        precondition(Array(self.group.makeIterator()).count == 1)
        return self.loop._selector as! HookedSelector
    }

    private var loop: SelectableEventLoop {
        precondition(Array(self.group.makeIterator()).count == 1)
        return ((self.group!.next()) as! SelectableEventLoop)
    }

    func setUpSAL() {
        XCTAssertNil(self.group)
        XCTAssertNil(self.kernelToUserBox)
        XCTAssertNil(self.userToKernelBox)
        XCTAssertNil(self.wakeups)
        self.kernelToUserBox = .init(description: "k2u") { newValue in
            if let newValue = newValue {
                SAL.printIfDebug("K --> U: \(newValue)")
            }
        }
        self.userToKernelBox = .init(description: "u2k") { newValue in
            if let newValue = newValue {
                SAL.printIfDebug("U --> K: \(newValue)")
            }
        }
        self.wakeups = .init(description: "wakeups")
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1) {
            try HookedSelector(userToKernel: self.userToKernelBox,
                               kernelToUser: self.kernelToUserBox,
                               wakeups: self.wakeups)
        }
    }

    private func makeSocketChannel(eventLoop: SelectableEventLoop,
                                   file: StaticString = #filePath, line: UInt = #line) throws -> SocketChannel {
        let channel = try eventLoop.runSAL(syscallAssertions: {
            try self.assertdisableSIGPIPE(expectedFD: .max, result: .success(()))
            try self.assertLocalAddress(address: nil)
            try self.assertRemoteAddress(address: nil)
        }) {
            try SocketChannel(socket: HookedSocket(userToKernel: self.userToKernelBox,
                                                   kernelToUser: self.kernelToUserBox,
                                                   socket: .max),
                              eventLoop: eventLoop)
        }
        try self.assertParkedRightNow()
        return channel
    }

    private func makeServerSocketChannel(eventLoop: SelectableEventLoop,
                                         group: MultiThreadedEventLoopGroup,
                                         file: StaticString = #filePath, line: UInt = #line) throws -> ServerSocketChannel {
        let channel = try eventLoop.runSAL(syscallAssertions: {
            try self.assertdisableSIGPIPE(expectedFD: .max, result: .success(()))
            try self.assertLocalAddress(address: nil)
            try self.assertRemoteAddress(address: nil)
        }) {
            try ServerSocketChannel(serverSocket: HookedServerSocket(userToKernel: self.userToKernelBox,
                                                                     kernelToUser: self.kernelToUserBox,
                                                                     socket: .max),
                                    eventLoop: eventLoop,
                                    group: group
            )
        }
        try self.assertParkedRightNow()
        return channel
    }

    func makeSocketChannelInjectingFailures(disableSIGPIPEFailure: IOError?) throws -> SocketChannel {
        let channel = try self.loop.runSAL(syscallAssertions: {
            try self.assertdisableSIGPIPE(expectedFD: .max,
                                         result: disableSIGPIPEFailure.map {
                                            Result<Void, IOError>.failure($0)
                                         } ?? .success(()))
            guard disableSIGPIPEFailure == nil else {
                // if F_NOSIGPIPE failed, we shouldn't see other syscalls.
                return
            }
            try self.assertLocalAddress(address: nil)
            try self.assertRemoteAddress(address: nil)
        }) {
            try SocketChannel(socket: HookedSocket(userToKernel: self.userToKernelBox,
                                                   kernelToUser: self.kernelToUserBox,
                                                   socket: .max),
                              eventLoop: self.loop)
        }
        try self.assertParkedRightNow()
        return channel
    }

    func makeSocketChannel(file: StaticString = #filePath, line: UInt = #line) throws -> SocketChannel {
        return try self.makeSocketChannel(eventLoop: self.loop, file: (file), line: line)
    }

    func makeServerSocketChannel(file: StaticString = #filePath, line: UInt = #line) throws -> ServerSocketChannel {
        return try self.makeServerSocketChannel(eventLoop: self.loop, group: self.group, file: (file), line: line)
    }

    func makeConnectedSocketChannel(localAddress: SocketAddress?,
                                    remoteAddress: SocketAddress,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) throws -> SocketChannel {
        let channel = try self.makeSocketChannel(eventLoop: self.loop)
        let connectFuture = try channel.eventLoop.runSAL(syscallAssertions: {
            try self.assertConnect(expectedAddress: remoteAddress, result: true)
            try self.assertLocalAddress(address: localAddress)
            try self.assertRemoteAddress(address: remoteAddress)
            try self.assertRegister { selectable, eventSet, registration in
                if case (.socketChannel(let channel), let registrationEventSet) =
                    (registration.channel, registration.interested) {

                    XCTAssertEqual(localAddress, channel.localAddress)
                    XCTAssertEqual(remoteAddress, channel.remoteAddress)
                    XCTAssertEqual(eventSet, registrationEventSet)
                    XCTAssertEqual(.reset, eventSet)
                    return true
                } else {
                    return false
                }
            }
            try self.assertReregister { selectable, eventSet in
                XCTAssertEqual([.reset, .readEOF], eventSet)
                return true
            }
            // because autoRead is on by default
            try self.assertReregister { selectable, eventSet in
                XCTAssertEqual([.reset, .readEOF, .read], eventSet)
                return true
            }
        }) {
            channel.register().flatMap {
                channel.connect(to: remoteAddress)
            }
        }
        XCTAssertNoThrow(try connectFuture.salWait())
        return channel
    }

    func makeBoundServerSocketChannel(localAddress: SocketAddress,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) throws -> ServerSocketChannel {
        let channel = try self.makeServerSocketChannel(eventLoop: self.loop, group: self.group)
        let bindFuture = try channel.eventLoop.runSAL(syscallAssertions: {
            try self.assertBind(expectedAddress: localAddress)
            try self.assertLocalAddress(address: localAddress)
            try self.assertListen(expectedFD: .max, expectedBacklog: 128)
            try self.assertRegister { selectable, eventSet, registration in
                if case (.serverSocketChannel(let channel), let registrationEventSet) =
                    (registration.channel, registration.interested) {

                    XCTAssertEqual(localAddress, channel.localAddress)
                    XCTAssertEqual(nil, channel.remoteAddress)
                    XCTAssertEqual(eventSet, registrationEventSet)
                    XCTAssertEqual(.reset, eventSet)
                    return true
                } else {
                    return false
                }
            }
            try self.assertReregister { selectable, eventSet in
                XCTAssertEqual([.reset, .readEOF], eventSet)
                return true
            }
            // because autoRead is on by default
            try self.assertReregister { selectable, eventSet in
                XCTAssertEqual([.reset, .readEOF, .read], eventSet)
                return true
            }
        }) {
            channel.register().flatMap {
                channel.bind(to: localAddress)
            }
        }
        XCTAssertNoThrow(try bindFuture.salWait())
        return channel
    }

    func makeSocket() throws -> HookedSocket {
        return try self.loop.runSAL(syscallAssertions: {
            try self.assertdisableSIGPIPE(expectedFD: .max, result: .success(()))
        }) {
            try HookedSocket(userToKernel: self.userToKernelBox, kernelToUser: self.kernelToUserBox, socket: .max)
        }
    }

    func tearDownSAL() {
        SAL.printIfDebug("=== TEAR DOWN ===")
        XCTAssertNotNil(self.kernelToUserBox)
        XCTAssertNotNil(self.userToKernelBox)
        XCTAssertNotNil(self.wakeups)
        XCTAssertNotNil(self.group)

        let group = DispatchGroup()
        group.enter()
        XCTAssertNoThrow(self.group.shutdownGracefully(queue: DispatchQueue.global()) { error in
            XCTAssertNil(error, "unexpected error: \(error!)")
            group.leave()
        })
        // We're in a slightly tricky situation here. We don't know if the EventLoop thread enters `whenReady` again
        // or not. If it has, we have to wake it up, so let's just put a return value in the 'kernel to user' box, just
        // in case :)
        XCTAssertNoThrow(try self.kernelToUserBox.waitForEmptyAndSet(.returnSelectorEvent(nil)))
        group.wait()

        self.group = nil
        self.kernelToUserBox = nil
        self.userToKernelBox = nil
        self.wakeups = nil
    }

    func assertParkedRightNow(file: StaticString = #filePath, line: UInt = #line) throws {
        try self.userToKernelBox.assertParkedRightNow(file: file, line: line)
    }

    func assertWaitingForNotification(result: SelectorEvent<NIORegistration>?,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        SAL.printIfDebug("\(#function)(result: \(result.debugDescription))")
        try self.selector.assertSyscallAndReturn(.returnSelectorEvent(result),
                                                 file: (file), line: line) { syscall in
            if case .whenReady = syscall {
                return true
            } else {
                return false
            }
        }
    }

    func assertWakeup(file: StaticString = #filePath, line: UInt = #line) throws {
        try self.selector.assertWakeup(file: (file), line: line)
    }

    func assertdisableSIGPIPE(expectedFD: CInt,
                             result: Result<Void, IOError>,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        SAL.printIfDebug("\(#function)")
        let ret: KernelToUser
        switch result {
        case .success:
            ret = .returnVoid
        case .failure(let error):
            ret = .error(error)
        }
        try self.selector.assertSyscallAndReturn(ret, file: (file), line: line) { syscall in
            if case .disableSIGPIPE(expectedFD) = syscall {
                return true
            } else {
                return false
            }
        }
    }


    func assertLocalAddress(address: SocketAddress?, file: StaticString = #filePath, line: UInt = #line) throws {
        SAL.printIfDebug("\(#function)")
        try self.selector.assertSyscallAndReturn(address.map {
                                                    .returnSocketAddress($0)
            /*                                */ } ?? .error(IOError(errnoCode: EOPNOTSUPP, reason: "nil passed")),
                                                 file: (file), line: line) { syscall in
            if case .localAddress = syscall {
                return true
            } else {
                return false
            }
        }
    }

    func assertRemoteAddress(address: SocketAddress?, file: StaticString = #filePath, line: UInt = #line) throws {
        SAL.printIfDebug("\(#function)")
        try self.selector.assertSyscallAndReturn(address.map { .returnSocketAddress($0) } ??
            /*                                */ .error(IOError(errnoCode: EOPNOTSUPP, reason: "nil passed")),
                                                 file: (file), line: line) { syscall in
            if case .remoteAddress = syscall {
                return true
            } else {
                return false
            }
        }
    }

    func assertConnect(expectedAddress: SocketAddress, result: Bool, file: StaticString = #filePath, line: UInt = #line, _ matcher: (SocketAddress) -> Bool = { _ in true }) throws {
        SAL.printIfDebug("\(#function)")
        try self.selector.assertSyscallAndReturn(.returnBool(result), file: (file), line: line) { syscall in
            if case .connect(let address) = syscall {
                return address == expectedAddress
            } else {
                return false
            }
        }
    }

    func assertBind(expectedAddress: SocketAddress, file: StaticString = #filePath, line: UInt = #line) throws {
        SAL.printIfDebug("\(#function)")
        try self.selector.assertSyscallAndReturn(.returnVoid, file: (file), line: line) { syscall in
            if case .bind(let address) = syscall {
                return address == expectedAddress
            } else {
                return false
            }
        }
    }

    func assertClose(expectedFD: CInt, file: StaticString = #filePath, line: UInt = #line) throws {
        SAL.printIfDebug("\(#function)")
        try self.selector.assertSyscallAndReturn(.returnVoid, file: (file), line: line) { syscall in
            if case .close(let fd) = syscall {
                XCTAssertEqual(expectedFD, fd, file: (file), line: line)
                return true
            } else {
                return false
            }
        }
    }

    func assertSetOption(expectedLevel: NIOBSDSocket.OptionLevel,
                         expectedOption: NIOBSDSocket.Option,
                         file: StaticString = #filePath, line: UInt = #line,
                         _ valueMatcher: (Any) -> Bool = { _ in true }) throws {
        SAL.printIfDebug("\(#function)")
        try self.selector.assertSyscallAndReturn(.returnVoid, file: (file), line: line) { syscall in
            if case .setOption(expectedLevel, expectedOption, let value) = syscall {
                return valueMatcher(value)
            } else {
                return false
            }
        }
    }

    func assertRegister(file: StaticString = #filePath, line: UInt = #line, _ matcher: (Selectable, SelectorEventSet, NIORegistration) throws -> Bool) throws {
        SAL.printIfDebug("\(#function)")
        try self.selector.assertSyscallAndReturn(.returnVoid, file: (file), line: line) { syscall in
            if case .register(let selectable, let eventSet, let registration) = syscall {
                return try matcher(selectable, eventSet, registration)
            } else {
                return false
            }
        }
    }

    func assertReregister(file: StaticString = #filePath, line: UInt = #line, _ matcher: (Selectable, SelectorEventSet) throws -> Bool) throws {
        SAL.printIfDebug("\(#function)")
        try self.selector.assertSyscallAndReturn(.returnVoid, file: (file), line: line) { syscall in
            if case .reregister(let selectable, let eventSet) = syscall {
                return try matcher(selectable, eventSet)
            } else {
                return false
            }
        }
    }

    func assertDeregister(file: StaticString = #filePath, line: UInt = #line, _ matcher: (Selectable) throws -> Bool) throws {
        SAL.printIfDebug("\(#function)")
        try self.selector.assertSyscallAndReturn(.returnVoid, file: (file), line: line) { syscall in
            if case .deregister(let selectable) = syscall {
                return try matcher(selectable)
            } else {
                return false
            }
        }
    }

    func assertWrite(expectedFD: CInt, expectedBytes: ByteBuffer, return: IOResult<Int>, file: StaticString = #filePath, line: UInt = #line) throws {
        SAL.printIfDebug("\(#function)")
        try self.selector.assertSyscallAndReturn(.returnIOResultInt(`return`), file: (file), line: line) { syscall in
            if case .write(let actualFD, let actualBytes) = syscall {
                return expectedFD == actualFD && expectedBytes == actualBytes
            } else {
                return false
            }
        }
    }

    func assertWritev(expectedFD: CInt, expectedBytes: [ByteBuffer], return: IOResult<Int>, file: StaticString = #filePath, line: UInt = #line) throws {
        SAL.printIfDebug("\(#function)")
        try self.selector.assertSyscallAndReturn(.returnIOResultInt(`return`), file: (file), line: line) { syscall in
            if case .writev(let actualFD, let actualBytes) = syscall {
                return expectedFD == actualFD && expectedBytes == actualBytes
            } else {
                return false
            }
        }
    }

    func assertRead(expectedFD: CInt, expectedBufferSpace: Int, return: ByteBuffer,
                    file: StaticString = #filePath, line: UInt = #line) throws {
        SAL.printIfDebug("\(#function)")
        try self.selector.assertSyscallAndReturn(.returnBytes(`return`),
                                                 file: (file), line: line) { syscall in
            if case .read(let amount) = syscall {
                XCTAssertEqual(expectedBufferSpace, amount, file: (file), line: line)
                return true
            } else {
                return false
            }
        }
    }

    func assertListen(expectedFD: CInt, expectedBacklog: CInt, file: StaticString = #filePath, line: UInt = #line) throws {
        SAL.printIfDebug("\(#function)")
        try self.selector.assertSyscallAndReturn(.returnVoid,
                                                 file: (file), line: line) { syscall in
            if case .listen(let fd, let backlog) = syscall {
                XCTAssertEqual(fd, expectedFD, file: (file), line: line)
                XCTAssertEqual(backlog, expectedBacklog, file: (file), line: line)
                return true
            } else {
                return false
            }
        }
    }

    func assertAccept(expectedFD: CInt, expectedNonBlocking: Bool, return: Socket?,
                      file: StaticString = #filePath, line: UInt = #line) throws {
        SAL.printIfDebug("\(#function)")
        try self.selector.assertSyscallAndReturn(.returnSocket(`return`),
                                                 file: (file), line: line) { syscall in
            if case .accept(let fd, let nonBlocking) = syscall {
                XCTAssertEqual(fd, expectedFD, file: (file), line: line)
                XCTAssertEqual(nonBlocking, expectedNonBlocking, file: (file), line: line)
                return true
            } else {
                return false
            }
        }
    }

    func assertAccept(expectedFD: CInt, expectedNonBlocking: Bool, throwing error: Error,
                      file: StaticString = #filePath, line: UInt = #line) throws {
        SAL.printIfDebug("\(#function)")
        try self.selector.assertSyscallAndReturn(.error(error),
                                                 file: (file), line: line) { syscall in
            if case .accept(let fd, let nonBlocking) = syscall {
                XCTAssertEqual(fd, expectedFD, file: (file), line: line)
                XCTAssertEqual(nonBlocking, expectedNonBlocking, file: (file), line: line)
                return true
            } else {
                return false
            }
        }
    }

    func waitForNextSyscall() throws -> UserToKernel {
        return try self.userToKernelBox.waitForValue()
    }
}
