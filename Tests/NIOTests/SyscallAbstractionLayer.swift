//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
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

@testable import NIO
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
            didSet(_value)
        }
    }

    init(_ value: T? = nil,
         description: String? = nil,
         file: StaticString = #file,
         line: UInt = #line,
         didSet: @escaping (T?) -> Void = { _ in })
    {
        _value = value
        self.didSet = didSet
        self.description = description ?? "\(file):\(line)"
    }

    internal var value: T? {
        get {
            condition.lock()
            defer {
                self.condition.unlock()
            }
            return _value
        }

        set {
            condition.lock()
            if let value = newValue {
                _value = value
                condition.unlock(withValue: 1)
            } else {
                _value = nil
                condition.unlock(withValue: 0)
            }
        }
    }

    func waitForEmptyAndSet(_ value: T) throws {
        if condition.lock(whenValue: 0, timeoutSeconds: SAL.defaultTimeout) {
            defer {
                self.condition.unlock(withValue: 1)
            }
            _value = value
        } else {
            throw TimeoutError(description)
        }
    }

    func takeValue() throws -> T {
        if condition.lock(whenValue: 1, timeoutSeconds: SAL.defaultTimeout) {
            defer {
                self.condition.unlock(withValue: 0)
            }
            let value = _value!
            _value = nil
            return value
        } else {
            throw TimeoutError(description)
        }
    }

    func waitForValue() throws -> T {
        if condition.lock(whenValue: 1, timeoutSeconds: SAL.defaultTimeout) {
            defer {
                self.condition.unlock(withValue: 1)
            }
            return _value!
        } else {
            throw TimeoutError(description)
        }
    }
}

extension LockedBox where T == UserToKernel {
    func assertParkedRightNow(file: StaticString = #file, line: UInt = #line) throws {
        SAL.printIfDebug("\(#function)")
        let syscall = try waitForValue()
        if case .whenReady(.block) = syscall {
            return
        } else {
            XCTFail("unexpected syscall \(syscall)", file: file, line: line)
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
}

enum KernelToUser {
    case returnSocketAddress(SocketAddress)
    case returnBool(Bool)
    case returnBytes(ByteBuffer)
    case returnVoid
    case returnSelectorEvent(SelectorEvent<NIORegistration>?)
    case returnIOResultInt(IOResult<Int>)
    case error(IOError)
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

private extension UserKernelInterface {
    func waitForKernelReturn() throws -> KernelToUser {
        let value = try kernelToUser.takeValue()
        if case let .error(error) = value {
            throw error
        } else {
            return value
        }
    }
}

internal class HookedSelector: NIO.Selector<NIORegistration>, UserKernelInterface {
    fileprivate let userToKernel: LockedBox<UserToKernel>
    fileprivate let kernelToUser: LockedBox<KernelToUser>
    fileprivate let wakeups: LockedBox<Void>

    init(userToKernel: LockedBox<UserToKernel>, kernelToUser: LockedBox<KernelToUser>, wakeups: LockedBox<Void>) throws {
        self.userToKernel = userToKernel
        self.kernelToUser = kernelToUser
        self.wakeups = wakeups
        try super.init()
        lifecycleState = .open
    }

    override func register<S: Selectable>(selectable: S,
                                          interested: SelectorEventSet,
                                          makeRegistration: (SelectorEventSet, SelectorRegistrationID) -> NIORegistration) throws
    {
        try userToKernel.waitForEmptyAndSet(.register(selectable, interested, makeRegistration(interested,
                                                                                               .initialRegistrationID)))
        let ret = try waitForKernelReturn()
        if case .returnVoid = ret {
            return
        } else {
            throw UnexpectedKernelReturn(ret)
        }
    }

    override func reregister<S: Selectable>(selectable: S, interested: SelectorEventSet) throws {
        try userToKernel.waitForEmptyAndSet(.reregister(selectable, interested))
        let ret = try waitForKernelReturn()
        if case .returnVoid = ret {
            return
        } else {
            throw UnexpectedKernelReturn(ret)
        }
    }

    override func whenReady(strategy: SelectorStrategy, onLoopBegin loopStart: () -> Void, _ body: (SelectorEvent<NIORegistration>) throws -> Void) throws {
        try userToKernel.waitForEmptyAndSet(.whenReady(strategy))
        let ret = try waitForKernelReturn()
        if case let .returnSelectorEvent(event) = ret {
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
        try userToKernel.waitForEmptyAndSet(.deregister(selectable))
        let ret = try waitForKernelReturn()
        if case .returnVoid = ret {
            return
        } else {
            throw UnexpectedKernelReturn(ret)
        }
    }

    override func wakeup() throws {
        SAL.printIfDebug("WAKEUP")
        try wakeups.waitForEmptyAndSet(())
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
        try withUnsafeHandle { fd in
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
        try userToKernel.waitForEmptyAndSet(.localAddress)
        let ret = try waitForKernelReturn()
        if case let .returnSocketAddress(address) = ret {
            return address
        } else {
            throw UnexpectedKernelReturn(ret)
        }
    }

    override func remoteAddress() throws -> SocketAddress {
        try userToKernel.waitForEmptyAndSet(.remoteAddress)
        let ret = try waitForKernelReturn()
        if case let .returnSocketAddress(address) = ret {
            return address
        } else {
            throw UnexpectedKernelReturn(ret)
        }
    }

    override func connect(to address: SocketAddress) throws -> Bool {
        try userToKernel.waitForEmptyAndSet(.connect(address))
        let ret = try waitForKernelReturn()
        if case let .returnBool(success) = ret {
            return success
        } else {
            throw UnexpectedKernelReturn(ret)
        }
    }

    override func read(pointer: UnsafeMutableRawBufferPointer) throws -> IOResult<Int> {
        try userToKernel.waitForEmptyAndSet(.read(pointer.count))
        let ret = try waitForKernelReturn()
        if case let .returnBytes(buffer) = ret {
            assert(buffer.readableBytes <= pointer.count)
            pointer.copyBytes(from: buffer.readableBytesView)
            return .processed(buffer.readableBytes)
        } else {
            throw UnexpectedKernelReturn(ret)
        }
    }

    override func write(pointer: UnsafeRawBufferPointer) throws -> IOResult<Int> {
        try withUnsafeHandle { fd in
            var buffer = ByteBufferAllocator().buffer(capacity: pointer.count)
            buffer.writeBytes(pointer)
            try self.userToKernel.waitForEmptyAndSet(.write(fd, buffer))
            let ret = try self.waitForKernelReturn()
            if case let .returnIOResultInt(result) = ret {
                return result
            } else {
                throw UnexpectedKernelReturn(ret)
            }
        }
    }

    override func writev(iovecs: UnsafeBufferPointer<IOVector>) throws -> IOResult<Int> {
        try withUnsafeHandle { fd in
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
            if case let .returnIOResultInt(result) = ret {
                return result
            } else {
                throw UnexpectedKernelReturn(ret)
            }
        }
    }

    override func close() throws {
        let fd = try takeDescriptorOwnership()

        try userToKernel.waitForEmptyAndSet(.close(fd))
        let ret = try waitForKernelReturn()
        if case .returnVoid = ret {
            return
        } else {
            throw UnexpectedKernelReturn(ret)
        }
    }

    override func setOption<T>(level: NIOBSDSocket.OptionLevel, name: NIOBSDSocket.Option, value: T) throws {
        try userToKernel.waitForEmptyAndSet(.setOption(level, name, value))
        let ret = try waitForKernelReturn()
        if case .returnVoid = ret {
            return
        } else {
            throw UnexpectedKernelReturn(ret)
        }
    }

    override func bind(to address: SocketAddress) throws {
        try userToKernel.waitForEmptyAndSet(.bind(address))
        let ret = try waitForKernelReturn()
        if case .returnVoid = ret {
            return
        } else {
            throw UnexpectedKernelReturn(ret)
        }
    }
}

extension HookedSelector {
    func assertSyscallAndReturn(_ result: KernelToUser,
                                file: StaticString = #file,
                                line: UInt = #line,
                                matcher: (UserToKernel) throws -> Bool) throws
    {
        let syscall = try userToKernel.takeValue()
        if try matcher(syscall) {
            try kernelToUser.waitForEmptyAndSet(result)
        } else {
            XCTFail("unexpected syscall \(syscall)", file: file, line: line)
            throw UnexpectedSyscall(syscall)
        }
    }

    /// This function will wait for an event loop wakeup until it unblocks. If the event loop
    /// is currently executing then it will not be woken: as a result, consider using
    /// `assertParkedRightNow` before the event that you want to trigger the wakeup, and before calling
    /// this code.
    func assertWakeup(file: StaticString = #file, line: UInt = #line) throws {
        SAL.printIfDebug("\(#function)")
        try wakeups.takeValue()
        try assertSyscallAndReturn(.returnSelectorEvent(nil), file: file, line: line) { syscall in
            if case .whenReady(.block) = syscall {
                return true
            } else {
                return false
            }
        }
    }

    func assertParkedRightNow(file: StaticString = #file, line: UInt = #line) throws {
        try userToKernel.assertParkedRightNow(file: file, line: line)
    }
}

extension EventLoop {
    func runSAL<T>(syscallAssertions: () throws -> Void = {},
                   file: StaticString = #file,
                   line: UInt = #line,
                   _ body: @escaping () throws -> T) throws -> T
    {
        let hookedSelector = ((self as! SelectableEventLoop)._selector as! HookedSelector)
        let box = LockedBox<Result<T, Error>>()

        // To prevent races between the test driver thread (this thread) and the EventLoop (another thread), we need
        // to wait for the EventLoop to finish its tick and park itself. That makes sure both threads are synchronised
        // so we know exactly what the EventLoop thread is currently up to (nothing at all, waiting for a wakeup).
        try hookedSelector.userToKernel.assertParkedRightNow()

        execute {
            do {
                try box.waitForEmptyAndSet(.init(catching: body))
            } catch {
                box.value = .failure(error)
            }
        }
        try hookedSelector.assertWakeup(file: file, line: line)
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
    func salWait() throws -> Value {
        let box = LockedBox<Result<Value, Error>>()

        XCTAssertNoThrow(try eventLoop.runSAL {
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
    var wakeups: LockedBox<Void>! { get set }
    var userToKernelBox: LockedBox<UserToKernel>! { get set }
    var kernelToUserBox: LockedBox<KernelToUser>! { get set }
}

extension SALTest {
    private var selector: HookedSelector {
        precondition(Array(group.makeIterator()).count == 1)
        return loop._selector as! HookedSelector
    }

    private var loop: SelectableEventLoop {
        precondition(Array(group.makeIterator()).count == 1)
        return ((group!.next()) as! SelectableEventLoop)
    }

    func setUpSAL() {
        XCTAssertNil(group)
        XCTAssertNil(kernelToUserBox)
        XCTAssertNil(userToKernelBox)
        XCTAssertNil(wakeups)
        kernelToUserBox = .init(description: "k2u") { newValue in
            if let newValue = newValue {
                SAL.printIfDebug("K --> U: \(newValue)")
            }
        }
        userToKernelBox = .init(description: "u2k") { newValue in
            if let newValue = newValue {
                SAL.printIfDebug("U --> K: \(newValue)")
            }
        }
        wakeups = .init(description: "wakeups")
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1) {
            try HookedSelector(userToKernel: self.userToKernelBox,
                               kernelToUser: self.kernelToUserBox,
                               wakeups: self.wakeups)
        }
    }

    private func makeSocketChannel(eventLoop: SelectableEventLoop,
                                   file _: StaticString = #file, line _: UInt = #line) throws -> SocketChannel
    {
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
        try assertParkedRightNow()
        return channel
    }

    func makeSocketChannelInjectingFailures(disableSIGPIPEFailure: IOError?) throws -> SocketChannel {
        let channel = try loop.runSAL(syscallAssertions: {
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
        try assertParkedRightNow()
        return channel
    }

    func makeSocketChannel(file: StaticString = #file, line: UInt = #line) throws -> SocketChannel {
        try makeSocketChannel(eventLoop: loop, file: file, line: line)
    }

    func makeConnectedSocketChannel(localAddress: SocketAddress?,
                                    remoteAddress: SocketAddress,
                                    file _: StaticString = #file,
                                    line _: UInt = #line) throws -> SocketChannel
    {
        let channel = try makeSocketChannel(eventLoop: loop)
        let connectFuture = try channel.eventLoop.runSAL(syscallAssertions: {
            try self.assertConnect(expectedAddress: remoteAddress, result: true)
            try self.assertLocalAddress(address: localAddress)
            try self.assertRemoteAddress(address: remoteAddress)
            try self.assertRegister { _, eventSet, registration in
                if case let (.socketChannel(channel), registrationEventSet) =
                    (registration.channel, registration.interested)
                {
                    XCTAssertEqual(localAddress, channel.localAddress)
                    XCTAssertEqual(remoteAddress, channel.remoteAddress)
                    XCTAssertEqual(eventSet, registrationEventSet)
                    XCTAssertEqual(.reset, eventSet)
                    return true
                } else {
                    return false
                }
            }
            try self.assertReregister { _, eventSet in
                XCTAssertEqual([.reset, .readEOF], eventSet)
                return true
            }
            // because autoRead is on by default
            try self.assertReregister { _, eventSet in
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

    func tearDownSAL() {
        SAL.printIfDebug("=== TEAR DOWN ===")
        XCTAssertNotNil(kernelToUserBox)
        XCTAssertNotNil(userToKernelBox)
        XCTAssertNotNil(wakeups)
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
        XCTAssertNoThrow(try kernelToUserBox.waitForEmptyAndSet(.returnSelectorEvent(nil)))
        group.wait()

        self.group = nil
        kernelToUserBox = nil
        userToKernelBox = nil
        wakeups = nil
    }

    func assertParkedRightNow(file: StaticString = #file, line: UInt = #line) throws {
        try userToKernelBox.assertParkedRightNow(file: file, line: line)
    }

    func assertWaitingForNotification(result: SelectorEvent<NIORegistration>?,
                                      file: StaticString = #file, line: UInt = #line) throws
    {
        SAL.printIfDebug("\(#function)(result: \(result.debugDescription))")
        try selector.assertSyscallAndReturn(.returnSelectorEvent(result),
                                            file: file, line: line) { syscall in
            if case .whenReady = syscall {
                return true
            } else {
                return false
            }
        }
    }

    func assertWakeup(file: StaticString = #file, line: UInt = #line) throws {
        try selector.assertWakeup(file: file, line: line)
    }

    func assertdisableSIGPIPE(expectedFD: CInt,
                              result: Result<Void, IOError>,
                              file: StaticString = #file, line: UInt = #line) throws
    {
        SAL.printIfDebug("\(#function)")
        let ret: KernelToUser
        switch result {
        case .success:
            ret = .returnVoid
        case let .failure(error):
            ret = .error(error)
        }
        try selector.assertSyscallAndReturn(ret, file: file, line: line) { syscall in
            if case .disableSIGPIPE(expectedFD) = syscall {
                return true
            } else {
                return false
            }
        }
    }

    func assertLocalAddress(address: SocketAddress?, file: StaticString = #file, line: UInt = #line) throws {
        SAL.printIfDebug("\(#function)")
        try selector.assertSyscallAndReturn(address.map {
            .returnSocketAddress($0)
        /*                                */ } ?? .error(.init(errnoCode: EOPNOTSUPP, reason: "nil passed")),
        file: file, line: line) { syscall in
                if case .localAddress = syscall {
                    return true
                } else {
                    return false
                }
        }
    }

    func assertRemoteAddress(address: SocketAddress?, file: StaticString = #file, line: UInt = #line) throws {
        SAL.printIfDebug("\(#function)")
        try selector.assertSyscallAndReturn(address.map { .returnSocketAddress($0) } ??
            /*                                */ .error(.init(errnoCode: EOPNOTSUPP, reason: "nil passed")),
            file: file, line: line) { syscall in
                if case .remoteAddress = syscall {
                    return true
                } else {
                    return false
                }
        }
    }

    func assertConnect(expectedAddress: SocketAddress, result: Bool, file: StaticString = #file, line: UInt = #line, _: (SocketAddress) -> Bool = { _ in true }) throws {
        SAL.printIfDebug("\(#function)")
        try selector.assertSyscallAndReturn(.returnBool(result), file: file, line: line) { syscall in
            if case let .connect(address) = syscall {
                return address == expectedAddress
            } else {
                return false
            }
        }
    }

    func assertBind(expectedAddress: SocketAddress, file: StaticString = #file, line: UInt = #line) throws {
        SAL.printIfDebug("\(#function)")
        try selector.assertSyscallAndReturn(.returnVoid, file: file, line: line) { syscall in
            if case let .bind(address) = syscall {
                return address == expectedAddress
            } else {
                return false
            }
        }
    }

    func assertClose(expectedFD: CInt, file: StaticString = #file, line: UInt = #line) throws {
        SAL.printIfDebug("\(#function)")
        try selector.assertSyscallAndReturn(.returnVoid, file: file, line: line) { syscall in
            if case let .close(fd) = syscall {
                XCTAssertEqual(expectedFD, fd, file: file, line: line)
                return true
            } else {
                return false
            }
        }
    }

    func assertSetOption(expectedLevel: NIOBSDSocket.OptionLevel,
                         expectedOption: NIOBSDSocket.Option,
                         file: StaticString = #file, line: UInt = #line,
                         _ valueMatcher: (Any) -> Bool = { _ in true }) throws
    {
        SAL.printIfDebug("\(#function)")
        try selector.assertSyscallAndReturn(.returnVoid, file: file, line: line) { syscall in
            if case .setOption(expectedLevel, expectedOption, let value) = syscall {
                return valueMatcher(value)
            } else {
                return false
            }
        }
    }

    func assertRegister(file: StaticString = #file, line: UInt = #line, _ matcher: (Selectable, SelectorEventSet, NIORegistration) throws -> Bool) throws {
        SAL.printIfDebug("\(#function)")
        try selector.assertSyscallAndReturn(.returnVoid, file: file, line: line) { syscall in
            if case let .register(selectable, eventSet, registration) = syscall {
                return try matcher(selectable, eventSet, registration)
            } else {
                return false
            }
        }
    }

    func assertReregister(file: StaticString = #file, line: UInt = #line, _ matcher: (Selectable, SelectorEventSet) throws -> Bool) throws {
        SAL.printIfDebug("\(#function)")
        try selector.assertSyscallAndReturn(.returnVoid, file: file, line: line) { syscall in
            if case let .reregister(selectable, eventSet) = syscall {
                return try matcher(selectable, eventSet)
            } else {
                return false
            }
        }
    }

    func assertDeregister(file: StaticString = #file, line: UInt = #line, _ matcher: (Selectable) throws -> Bool) throws {
        SAL.printIfDebug("\(#function)")
        try selector.assertSyscallAndReturn(.returnVoid, file: file, line: line) { syscall in
            if case let .deregister(selectable) = syscall {
                return try matcher(selectable)
            } else {
                return false
            }
        }
    }

    func assertWrite(expectedFD: CInt, expectedBytes: ByteBuffer, return: IOResult<Int>, file: StaticString = #file, line: UInt = #line) throws {
        SAL.printIfDebug("\(#function)")
        try selector.assertSyscallAndReturn(.returnIOResultInt(`return`), file: file, line: line) { syscall in
            if case let .write(actualFD, actualBytes) = syscall {
                return expectedFD == actualFD && expectedBytes == actualBytes
            } else {
                return false
            }
        }
    }

    func assertWritev(expectedFD: CInt, expectedBytes: [ByteBuffer], return: IOResult<Int>, file: StaticString = #file, line: UInt = #line) throws {
        SAL.printIfDebug("\(#function)")
        try selector.assertSyscallAndReturn(.returnIOResultInt(`return`), file: file, line: line) { syscall in
            if case let .writev(actualFD, actualBytes) = syscall {
                return expectedFD == actualFD && expectedBytes == actualBytes
            } else {
                return false
            }
        }
    }

    func assertRead(expectedFD _: CInt, expectedBufferSpace: Int, return: ByteBuffer,
                    file: StaticString = #file, line: UInt = #line) throws
    {
        SAL.printIfDebug("\(#function)")
        try selector.assertSyscallAndReturn(.returnBytes(`return`),
                                            file: file, line: line) { syscall in
            if case let .read(amount) = syscall {
                XCTAssertEqual(expectedBufferSpace, amount, file: file, line: line)
                return true
            } else {
                return false
            }
        }
    }

    func waitForNextSyscall() throws -> UserToKernel {
        try userToKernelBox.waitForValue()
    }
}
