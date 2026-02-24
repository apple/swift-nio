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
//
// The SAL tests are pretty darn awkward with respect to sendability.
//
// Each SAL test is setup such that it can run some work on an event loop whose
// selector has been hooked such that it signals various events to locked
// containers. Another closure in each test can make assertions on the values of
// these containers, waiting for them to happen. These run in lock step. It
// means that various very much not sendable values must be transferred between
// isoaltion domains (the event loop and the calling thread). In general this
// isn't safe as non-sendable values could be escaped. These tests are quite
// careful to avoid that. This does however, mean that annotating types
// appropriately in order for the compiler to catch thread safety warnings is
// difficult.
//
// The current setup requires a 'SALContext' which holds the hooked event
// loop and various locked containers. It's also responsible for the lifecycle
// of these objects.
//
// The context also provides you with various methods for running a SAL test on
// the hooked event loop. Within that closure you're provided with the event
// loop and the user-to-kernel and kernel-to-user locked boxes. Another closure
// is also provided with an assertions object to wait for various events to
// happen.
//
// There are some sendability holes here:
//
// - LockedBox is unconditionally Sendable. It should only be Sendable when the
//   value it stores is Sendable.
// - Instances of LockedBox hold KernelToUser and UserToKernel types which are
//   *not* Sendable. These are shared between the event loop and the calling
//   thread.
// - HookedSocket isn't Sendable but is transferred between the EventLoop and
//   the calling thread in an UnsafeTransfer.

import CNIOLinux
import NIOConcurrencyHelpers
import NIOCore
import XCTest

@testable import NIOPosix

internal enum SAL {
    fileprivate static let defaultTimeout: Double = 5
    private static let debugTests: Bool = false
    static func printIfDebug(_ item: Any) {
        if debugTests {
            print(item)
        }
    }
}

final class LockedBox<T>: @unchecked Sendable {
    // @unchecked: _value is protected by a condition lock.
    // TODO: a condition-locked-value-box could hide some of the unchecked-ness here.

    struct TimeoutError: Error {
        var description: String
        init(_ description: String) {
            self.description = description
        }
    }
    struct ExpectedEmptyBox: Error {}

    private let condition = ConditionLock(value: 0)
    private let description: String
    private let didSet: @Sendable (T?) -> Void
    private var _value: T? {
        didSet {
            self.didSet(self._value)
        }
    }

    init(
        _ value: T? = nil,
        description: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line,
        didSet: @escaping @Sendable (T?) -> Void = { _ in }
    ) {
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

    func waitForLockedValue<R>(_ body: (T) throws -> R) throws -> R {
        if self.condition.lock(whenValue: 1, timeoutSeconds: SAL.defaultTimeout) {
            defer {
                self.condition.unlock(withValue: 1)
            }
            return try body(self._value!)
        } else {
            throw TimeoutError(self.description)
        }
    }
}

extension LockedBox where T == UserToKernel {
    func assertParkedRightNow(file: StaticString = #filePath, line: UInt = #line) throws {
        SAL.printIfDebug("\(#function)")
        try self.waitForLockedValue { syscall in
            if case .whenReady(.block) = syscall {
                return
            } else {
                XCTFail("unexpected syscall \(syscall)", file: (file), line: line)
            }
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
    case getOption(NIOBSDSocket.OptionLevel, NIOBSDSocket.Option)
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
    case returnAny(Any)
}

struct UnexpectedKernelReturn: Error {
    private var ret: String

    init(_ ret: KernelToUser) {
        self.ret = String(describing: ret)
    }
}

struct UnexpectedSyscall: Error {
    private var syscall: String

    init(_ syscall: UserToKernel) {
        self.syscall = String(describing: syscall)
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

    init(
        userToKernel: LockedBox<UserToKernel>,
        kernelToUser: LockedBox<KernelToUser>,
        wakeups: LockedBox<()>,
        thread: NIOThread
    ) throws {
        self.userToKernel = userToKernel
        self.kernelToUser = kernelToUser
        self.wakeups = wakeups
        try super.init(thread: thread)
        self.lifecycleState = .open
    }

    override func register<S: Selectable>(
        selectable: S,
        interested: SelectorEventSet,
        makeRegistration: (SelectorEventSet, SelectorRegistrationID) -> NIORegistration
    ) throws {
        try self.userToKernel.waitForEmptyAndSet(
            .register(
                selectable,
                interested,
                makeRegistration(
                    interested,
                    .initialRegistrationID
                )
            )
        )
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

    override func whenReady(
        strategy: SelectorStrategy,
        onLoopBegin loopStart: () -> Void,
        _ body: (SelectorEvent<NIORegistration>) throws -> Void
    ) throws {
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

    init(
        userToKernel: LockedBox<UserToKernel>,
        kernelToUser: LockedBox<KernelToUser>,
        socket: NIOBSDSocket.Handle
    ) throws {
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

final class HookedSocket: Socket, UserKernelInterface {
    fileprivate let userToKernel: LockedBox<UserToKernel>
    fileprivate let kernelToUser: LockedBox<KernelToUser>

    init(
        userToKernel: LockedBox<UserToKernel>,
        kernelToUser: LockedBox<KernelToUser>,
        socket: NIOBSDSocket.Handle
    ) throws {
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
        try self.withUnsafeHandle { fd in
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
        try self.withUnsafeHandle { fd in
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

    override func getOption<T>(level: NIOBSDSocket.OptionLevel, name: NIOBSDSocket.Option) throws -> T {
        try self.userToKernel.waitForEmptyAndSet(.getOption(level, name))
        let ret = try self.waitForKernelReturn()
        if case .returnAny(let any) = ret {
            return any as! T
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
    func assertSyscallAndReturn(
        _ result: KernelToUser,
        file: StaticString = #filePath,
        line: UInt = #line,
        matcher: (UserToKernel) throws -> Bool
    ) throws {
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

extension EventLoopFuture where Value: Sendable {
    /// This works like `EventLoopFuture.wait()` but can be used together with the SAL.
    ///
    /// Using a plain `EventLoopFuture.wait()` together with the SAL would require you to spin the `EventLoop` manually
    /// which is error prone and hard.
    func salWait(context: SALContext) throws -> Value {
        precondition(context.eventLoop === self.eventLoop)
        let box = LockedBox<Result<Value, Error>>()

        XCTAssertNoThrow(
            try context.runSALOnEventLoop { _, _, _ in
                self.whenComplete { value in
                    // We can bang this because the LockedBox is empty so it'll immediately succeed.
                    try! box.waitForEmptyAndSet(value)
                }
            }
        )

        return try box.waitForLockedValue { try $0.get() }
    }
}

extension SALContext {
    private func makeSocketChannel(
        eventLoop: SelectableEventLoop,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> SocketChannel {
        let channel = try self.runSALOnEventLoop { eventLoop, kernelToUser, userToKernel in
            try SocketChannel(
                socket: HookedSocket(
                    userToKernel: userToKernel,
                    kernelToUser: kernelToUser,
                    socket: .max
                ),
                eventLoop: eventLoop
            )
        } syscallAssertions: { assertions in
            try assertions.assertdisableSIGPIPE(expectedFD: .max, result: .success(()))
            try assertions.assertLocalAddress(address: nil)
            try assertions.assertRemoteAddress(address: nil)
            try assertions.assertParkedRightNow()
        }

        try self.selector.assertParkedRightNow()
        return channel
    }

    private func makeServerSocketChannel(
        eventLoop: SelectableEventLoop,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ServerSocketChannel {
        let channel = try self.runSALOnEventLoop { eventLoop, kernelToUser, userToKernel in
            try ServerSocketChannel(
                serverSocket: HookedServerSocket(
                    userToKernel: userToKernel,
                    kernelToUser: kernelToUser,
                    socket: .max
                ),
                eventLoop: eventLoop,
                group: eventLoop
            )
        } syscallAssertions: { assertions in
            try assertions.assertdisableSIGPIPE(expectedFD: .max, result: .success(()))
            try assertions.assertLocalAddress(address: nil)
            try assertions.assertRemoteAddress(address: nil)
        }

        try self.selector.assertParkedRightNow()
        return channel
    }

    func makeSocketChannelInjectingFailures(disableSIGPIPEFailure: IOError?) throws -> SocketChannel {
        let channel = try self.runSALOnEventLoop { eventLoop, kernelToUser, userToKernel in
            try SocketChannel(
                socket: HookedSocket(
                    userToKernel: userToKernel,
                    kernelToUser: kernelToUser,
                    socket: .max
                ),
                eventLoop: eventLoop
            )
        } syscallAssertions: { assertions in
            try assertions.assertdisableSIGPIPE(
                expectedFD: .max,
                result: disableSIGPIPEFailure.map {
                    Result<Void, IOError>.failure($0)
                } ?? .success(())
            )
            guard disableSIGPIPEFailure == nil else {
                // if F_NOSIGPIPE failed, we shouldn't see other syscalls.
                return
            }
            try assertions.assertLocalAddress(address: nil)
            try assertions.assertRemoteAddress(address: nil)
        }

        try self.selector.assertParkedRightNow()
        return channel
    }

    func makeSocketChannel(file: StaticString = #filePath, line: UInt = #line) throws -> SocketChannel {
        try self.makeSocketChannel(eventLoop: self.eventLoop, file: file, line: line)
    }

    func makeServerSocketChannel(file: StaticString = #filePath, line: UInt = #line) throws -> ServerSocketChannel {
        try self.makeServerSocketChannel(eventLoop: self.eventLoop, file: file, line: line)
    }

    func makeConnectedSocketChannel(
        localAddress: SocketAddress?,
        remoteAddress: SocketAddress,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> SocketChannel {
        let channel = try self.makeSocketChannel(eventLoop: self.eventLoop)
        try self.runSALOnEventLoopAndWait { _, _, _ in
            channel.register().flatMap {
                channel.connect(to: remoteAddress)
            }
        } syscallAssertions: { assertions in
            try assertions.assertConnect(expectedAddress: remoteAddress, result: true)
            try assertions.assertLocalAddress(address: localAddress)
            try assertions.assertRemoteAddress(address: remoteAddress)
            try assertions.assertRegister { selectable, eventSet, registration in
                if case (.socketChannel(let channel), let registrationEventSet) =
                    (registration.channel, registration.interested)
                {

                    XCTAssertEqual(localAddress, channel.localAddress)
                    XCTAssertEqual(remoteAddress, channel.remoteAddress)
                    XCTAssertEqual(eventSet, registrationEventSet)
                    XCTAssertEqual([.reset, .error], eventSet)
                    return true
                } else {
                    return false
                }
            }
            try assertions.assertReregister { selectable, eventSet in
                XCTAssertEqual([.reset, .error, .readEOF], eventSet)
                return true
            }
            // because autoRead is on by default
            try assertions.assertReregister { selectable, eventSet in
                XCTAssertEqual([.reset, .error, .readEOF, .read], eventSet)
                return true
            }
        }
        return channel
    }

    func makeBoundServerSocketChannel(
        localAddress: SocketAddress,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ServerSocketChannel {
        let channel = try self.makeServerSocketChannel(eventLoop: self.eventLoop)
        try self.runSALOnEventLoopAndWait { _, _, _ in
            channel.register().flatMap {
                channel.bind(to: localAddress)
            }
        } syscallAssertions: { assertions in
            try assertions.assertBind(expectedAddress: localAddress)
            try assertions.assertLocalAddress(address: localAddress)
            try assertions.assertListen(expectedFD: .max, expectedBacklog: 128)
            try assertions.assertRegister { selectable, eventSet, registration in
                if case (.serverSocketChannel(let channel), let registrationEventSet) =
                    (registration.channel, registration.interested)
                {

                    XCTAssertEqual(localAddress, channel.localAddress)
                    XCTAssertEqual(nil, channel.remoteAddress)
                    XCTAssertEqual(eventSet, registrationEventSet)
                    XCTAssertEqual([.reset, .error], eventSet)
                    return true
                } else {
                    return false
                }
            }
            try assertions.assertReregister { selectable, eventSet in
                XCTAssertEqual([.reset, .error, .readEOF], eventSet)
                return true
            }
            // because autoRead is on by default
            try assertions.assertReregister { selectable, eventSet in
                XCTAssertEqual([.reset, .error, .readEOF, .read], eventSet)
                return true
            }
        }
        return channel
    }

    func makeSocket() throws -> UnsafeTransfer<HookedSocket> {
        try self.runSALOnEventLoop { _, kernelToUser, userToKernel in
            let socket = try HookedSocket(userToKernel: userToKernel, kernelToUser: kernelToUser, socket: .max)
            return UnsafeTransfer(socket)
        } syscallAssertions: { assertions in
            try assertions.assertdisableSIGPIPE(expectedFD: .max, result: .success(()))
        }
    }

}

struct SyscallAssertions: @unchecked Sendable {
    // The HookedSelector _isn't_ Sendable and holds locked value boxes for types which also
    // aren't Sendable. However, these assertions are safe; they effectively wait on a locked
    // value and make assertions against them.
    private let selector: HookedSelector

    init(selector: HookedSelector) {
        self.selector = selector
    }

    func assertWaitingForNotification(
        result: SelectorEvent<NIORegistration>?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        SAL.printIfDebug("\(#function)(result: \(result.debugDescription))")
        try self.selector.assertSyscallAndReturn(
            .returnSelectorEvent(result),
            file: (file),
            line: line
        ) { syscall in
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

    func assertdisableSIGPIPE(
        expectedFD: CInt,
        result: Result<Void, IOError>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
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
        try self.selector.assertSyscallAndReturn(
            address.map {
                .returnSocketAddress($0)
            } ?? .error(IOError(errnoCode: EOPNOTSUPP, reason: "nil passed")),
            file: (file),
            line: line
        ) { syscall in
            if case .localAddress = syscall {
                return true
            } else {
                return false
            }
        }
    }

    func assertRemoteAddress(address: SocketAddress?, file: StaticString = #filePath, line: UInt = #line) throws {
        SAL.printIfDebug("\(#function)")
        try self.selector.assertSyscallAndReturn(
            address.map { .returnSocketAddress($0) } ?? .error(IOError(errnoCode: EOPNOTSUPP, reason: "nil passed")),
            file: (file),
            line: line
        ) { syscall in
            if case .remoteAddress = syscall {
                return true
            } else {
                return false
            }
        }
    }

    func assertConnect(
        expectedAddress: SocketAddress,
        result: Bool,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ matcher: (SocketAddress) -> Bool = { _ in true }
    ) throws {
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

    func assertGetOption<OptionValue>(
        expectedLevel: NIOBSDSocket.OptionLevel,
        expectedOption: NIOBSDSocket.Option,
        value: OptionValue,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        SAL.printIfDebug("\(#function)")
        try self.selector.assertSyscallAndReturn(.returnAny(value), file: (file), line: line) { syscall in
            if case .getOption(expectedLevel, expectedOption) = syscall {
                return true
            } else {
                return false
            }
        }
    }

    func assertSetOption(
        expectedLevel: NIOBSDSocket.OptionLevel,
        expectedOption: NIOBSDSocket.Option,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ valueMatcher: (Any) -> Bool = { _ in true }
    ) throws {
        SAL.printIfDebug("\(#function)")
        try self.selector.assertSyscallAndReturn(.returnVoid, file: (file), line: line) { syscall in
            if case .setOption(expectedLevel, expectedOption, let value) = syscall {
                return valueMatcher(value)
            } else {
                return false
            }
        }
    }

    func assertRegister(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ matcher: (Selectable, SelectorEventSet, NIORegistration) throws -> Bool
    ) throws {
        SAL.printIfDebug("\(#function)")
        try self.selector.assertSyscallAndReturn(.returnVoid, file: (file), line: line) { syscall in
            if case .register(let selectable, let eventSet, let registration) = syscall {
                return try matcher(selectable, eventSet, registration)
            } else {
                return false
            }
        }
    }

    func assertReregister(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ matcher: (Selectable, SelectorEventSet) throws -> Bool
    ) throws {
        SAL.printIfDebug("\(#function)")
        try self.selector.assertSyscallAndReturn(.returnVoid, file: (file), line: line) { syscall in
            if case .reregister(let selectable, let eventSet) = syscall {
                return try matcher(selectable, eventSet)
            } else {
                return false
            }
        }
    }

    func assertDeregister(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ matcher: (Selectable) throws -> Bool
    ) throws {
        SAL.printIfDebug("\(#function)")
        try self.selector.assertSyscallAndReturn(.returnVoid, file: (file), line: line) { syscall in
            if case .deregister(let selectable) = syscall {
                return try matcher(selectable)
            } else {
                return false
            }
        }
    }

    func assertWrite(
        expectedFD: CInt,
        expectedBytes: ByteBuffer,
        return: IOResult<Int>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        SAL.printIfDebug("\(#function)")
        try self.selector.assertSyscallAndReturn(.returnIOResultInt(`return`), file: (file), line: line) { syscall in
            if case .write(let actualFD, let actualBytes) = syscall {
                return expectedFD == actualFD && expectedBytes == actualBytes
            } else {
                return false
            }
        }
    }

    func assertWritev(
        expectedFD: CInt,
        expectedBytes: [ByteBuffer],
        return: IOResult<Int>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        SAL.printIfDebug("\(#function)")
        try self.selector.assertSyscallAndReturn(.returnIOResultInt(`return`), file: (file), line: line) { syscall in
            if case .writev(let actualFD, let actualBytes) = syscall {
                return expectedFD == actualFD && expectedBytes == actualBytes
            } else {
                return false
            }
        }
    }

    func assertRead(
        expectedFD: CInt,
        expectedBufferSpace: Int,
        return: ByteBuffer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        SAL.printIfDebug("\(#function)")
        try self.selector.assertSyscallAndReturn(
            .returnBytes(`return`),
            file: (file),
            line: line
        ) { syscall in
            if case .read(let amount) = syscall {
                XCTAssertEqual(expectedBufferSpace, amount, file: (file), line: line)
                return true
            } else {
                return false
            }
        }
    }

    func assertListen(
        expectedFD: CInt,
        expectedBacklog: CInt,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        SAL.printIfDebug("\(#function)")
        try self.selector.assertSyscallAndReturn(
            .returnVoid,
            file: (file),
            line: line
        ) { syscall in
            if case .listen(let fd, let backlog) = syscall {
                XCTAssertEqual(fd, expectedFD, file: (file), line: line)
                XCTAssertEqual(backlog, expectedBacklog, file: (file), line: line)
                return true
            } else {
                return false
            }
        }
    }

    func assertAccept(
        expectedFD: CInt,
        expectedNonBlocking: Bool,
        return: Socket?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        SAL.printIfDebug("\(#function)")
        try self.selector.assertSyscallAndReturn(
            .returnSocket(`return`),
            file: (file),
            line: line
        ) { syscall in
            if case .accept(let fd, let nonBlocking) = syscall {
                XCTAssertEqual(fd, expectedFD, file: (file), line: line)
                XCTAssertEqual(nonBlocking, expectedNonBlocking, file: (file), line: line)
                return true
            } else {
                return false
            }
        }
    }

    func assertAccept(
        expectedFD: CInt,
        expectedNonBlocking: Bool,
        throwing error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        SAL.printIfDebug("\(#function)")
        try self.selector.assertSyscallAndReturn(
            .error(error),
            file: (file),
            line: line
        ) { syscall in
            if case .accept(let fd, let nonBlocking) = syscall {
                XCTAssertEqual(fd, expectedFD, file: (file), line: line)
                XCTAssertEqual(nonBlocking, expectedNonBlocking, file: (file), line: line)
                return true
            } else {
                return false
            }
        }
    }

    func assertSyscallAndReturn(
        _ result: KernelToUser,
        file: StaticString = #filePath,
        line: UInt = #line,
        matcher: (UserToKernel) throws -> Bool
    ) throws {
        try self.selector.assertSyscallAndReturn(result, file: file, line: line, matcher: matcher)
    }

    func assertParkedRightNow(file: StaticString = #filePath, line: UInt = #line) throws {
        try self.selector.assertParkedRightNow(file: file, line: line)
    }
}
