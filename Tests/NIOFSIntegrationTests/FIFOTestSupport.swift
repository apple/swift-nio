//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// FIFOs are created with `mkfifo`, which is unavailable on Windows.
#if !os(Windows)
import NIOConcurrencyHelpers
import NIOCore
import NIOFS
import NIOPosix
import XCTest

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// Writing to a FIFO or pipe which has no reader raises SIGPIPE, which would take down the whole test process.
// Tests which fail part way through can leave the peer writing after the test has closed its end, so the
// peer's writes mustn't raise it: the peer sees `EPIPE` instead.
//
// As in NIOPosix, that's set on each descriptor on Darwin. Linux has no way to do that, so SIGPIPE is
// blocked on the peer's thread instead. That's enough on Linux, which raises SIGPIPE on the thread which
// wrote, but not on Darwin.

/// Stops writes to `descriptor` from raising SIGPIPE.
///
/// This only has an effect on Darwin: other platforms can't do this for a descriptor, see
/// ``blockSIGPIPEOnThisThread()``.
private func disableSIGPIPE(_ descriptor: FileDescriptor) throws {
    #if canImport(Darwin)
    guard fcntl(descriptor.rawValue, F_SETNOSIGPIPE, 1) == 0 else {
        throw FIFOPeerError.posix(call: "fcntl(F_SETNOSIGPIPE)", errno: errno)
    }
    #endif
}

/// Stops writes on the calling thread from raising SIGPIPE.
///
/// This has no effect on Darwin, where blocking SIGPIPE on the thread which writes doesn't stop it being
/// raised: see ``disableSIGPIPE(_:)``.
private func blockSIGPIPEOnThisThread() {
    #if !canImport(Darwin)
    var signals = sigset_t()
    sigemptyset(&signals)
    sigaddset(&signals, SIGPIPE)
    pthread_sigmask(SIG_BLOCK, &signals, nil)
    #endif
}

enum FIFOPeerError: Error, CustomStringConvertible {
    case posix(call: String, errno: Int32)
    case timedOut(String)
    case finishedEarly
    case testFinishedFirst(String)

    var description: String {
        switch self {
        case .posix(let call, let errno):
            return "\(call) failed: \(String(cString: strerror(errno))) (errno \(errno))"
        case .timedOut(let what):
            return "timed out: \(what)"
        case .finishedEarly:
            return "the peer finished before reaching the milestone"
        case .testFinishedFirst(let what):
            return "the test finished before \(what)"
        }
    }
}

/// Runs `peer` as the other end of the FIFO at `fifoPath` while running `test`, then waits for `peer` to
/// finish and returns what it produced.
///
/// The peer runs on a thread from a thread pool of its own, which is shut down before this returns. It
/// mustn't share a thread pool with the code under test: blocking opens of a FIFO would tie up threads that
/// the code under test needs to open the other end, which could deadlock.
///
/// Code under test which fails early can leave the peer blocked, either waiting to be released or in a
/// blocking `open`, which would otherwise cause the test to stop indefinitely. So if `test` throws, or
/// the peer doesn't finish in a timely fashion, the peer is forced to stop before this throws. If it
/// can't be stopped then its thread pool can't be shut down, which fails the test.
///
/// - Parameters:
///   - fifoPath: The path of the FIFO.
///   - outputType: The type of value returned by `peer`.
///   - peer: The work to do on the peer thread.
///   - test: The test, which may coordinate with the peer using the ``FIFOPeer`` passed to it.
/// - Returns: The value returned by `peer`.
func withFIFOPeer<Output: Sendable>(
    at fifoPath: FilePath,
    returning outputType: Output.Type = Output.self,
    file: StaticString = #filePath,
    line: UInt = #line,
    peer: @escaping @Sendable (FIFOPeer<Output>) throws -> Output,
    test: (FIFOPeer<Output>) async throws -> Void
) async throws -> Output {
    try await withPeer(FIFOPeer(fifoPath: fifoPath), file: file, line: line, peer: peer, test: test)
}

/// An end of a pipe.
enum PipeEnd {
    case read
    case write
}

/// Creates a pipe, then runs `peer` with one end of it while running `test` with the other, then waits for
/// `peer` to finish and returns what it produced.
///
/// `test` is given a path in `/dev/fd` for its end of the pipe, which it can open in the same way that a
/// program might open `/dev/stdin`. Opening it gives the test a descriptor of its own: the pipe's original
/// descriptor for that end is closed once `test` has finished.
///
/// The peer runs and is stopped in the same way as for ``withFIFOPeer(at:returning:file:line:peer:test:)``.
///
/// - Parameters:
///   - peerEnd: The end of the pipe to give to `peer`. The other end is used by `test`.
///   - outputType: The type of value returned by `peer`.
///   - peer: The work to do on the peer thread. It's given the descriptor of its end of the pipe, which is
///     closed when it returns.
///   - test: The test, which may coordinate with the peer using the ``FIFOPeer`` passed to it.
/// - Returns: The value returned by `peer`.
func withPipePeer<Output: Sendable>(
    peerEnd: PipeEnd,
    returning outputType: Output.Type = Output.self,
    file: StaticString = #filePath,
    line: UInt = #line,
    peer: @escaping @Sendable (FIFOPeer<Output>, FileDescriptor) throws -> Output,
    test: (FIFOPeer<Output>, _ path: FilePath) async throws -> Void
) async throws -> Output {
    let (readEnd, writeEnd) = try FileDescriptor.pipe()

    // This is the write end, whichever side has it. It covers the test's writes too: on Darwin, opening a
    // descriptor's path in `/dev/fd` shares its open file description, and so this setting.
    do {
        try disableSIGPIPE(writeEnd)
    } catch {
        try? readEnd.close()
        try? writeEnd.close()
        throw error
    }

    let peerDescriptor: FileDescriptor
    let testDescriptor: FileDescriptor
    switch peerEnd {
    case .read:
        (peerDescriptor, testDescriptor) = (readEnd, writeEnd)
    case .write:
        (peerDescriptor, testDescriptor) = (writeEnd, readEnd)
    }

    let testPath = FilePath("/dev/fd/\(testDescriptor.rawValue)")
    return try await withPeer(FIFOPeer(pipeTestEnd: testDescriptor), file: file, line: line) { fifoPeer in
        defer { try? peerDescriptor.close() }
        return try peer(fifoPeer, peerDescriptor)
    } test: { fifoPeer in
        try await test(fifoPeer, testPath)
    }
}

private func withPeer<Output: Sendable>(
    _ fifoPeer: FIFOPeer<Output>,
    file: StaticString,
    line: UInt,
    peer: @escaping @Sendable (FIFOPeer<Output>) throws -> Output,
    test: (FIFOPeer<Output>) async throws -> Void
) async throws -> Output {
    let threadPool = NIOThreadPool(numberOfThreads: 1)
    threadPool.start()

    threadPool.submit { workItemState in
        fifoPeer.run(peer, workItemState: workItemState)
    }

    let result: Result<Output, any Error>
    do {
        try await test(fifoPeer)
        fifoPeer.testDidFinish()
        result = .success(try await fifoPeer.waitForOutcome())
    } catch {
        fifoPeer.testDidFinish()
        await fifoPeer.abort()
        result = .failure(error)
    }

    if fifoPeer.hasFinished {
        try await threadPool.shutdownGracefully()
    } else {
        // Shutting down waits for the peer to finish, so it would stop indefinitely. No test leaves its peer
        // stuck on purpose, so this is always a failure. The peer's thread is left behind, and keeps the
        // thread pool alive: the pool is never deinitialized without having been shut down.
        XCTFail("The peer couldn't be stopped, so its thread pool was leaked", file: file, line: line)
    }

    return try result.get()
}

/// The other end of a FIFO or pipe, driven by blocking system calls on a thread of its own: see
/// ``withFIFOPeer(at:returning:file:line:peer:test:)`` and
/// ``withPipePeer(peerEnd:returning:file:line:peer:test:)``.
///
/// The peer doesn't use `FileSystem`, so that it doesn't depend on the code under test.
///
/// Coordination between the test and the peer is explicit:
/// - the test calls ``release()`` to let the peer continue past ``waitForRelease(timeout:)``;
/// - the peer calls ``reachMilestone()`` to let the test continue past ``waitForMilestone(timeout:)``;
/// - the peer can wait for the test to have finished with ``waitForTestToFinish(timeout:)``.
///
/// The peer blocks its own thread while it waits. The test side never blocks a thread: it polls with
/// `Task.sleep`, so it is safe to use from the Swift concurrency cooperative pool.
final class FIFOPeer<Output: Sendable>: Sendable {
    private struct State {
        var milestones = 0
        var outcome: Result<Output, any Error>?
        /// For a pipe: the pipe's original descriptor for the test's end, until it's closed.
        var pipeTestEnd: FileDescriptor?
    }

    private enum Connection {
        /// The peer opens the FIFO at this path.
        case fifo(path: FilePath)
        /// The peer was given one end of a pipe.
        case pipe
    }

    private let state: NIOLockedValueBox<State>

    /// Whether the test has released the peer.
    private let released = ConditionLock(value: false)

    /// Whether the test has finished.
    private let testFinished = ConditionLock(value: false)

    private let connection: Connection

    fileprivate init(fifoPath: FilePath) {
        self.state = NIOLockedValueBox(State())
        self.connection = .fifo(path: fifoPath)
    }

    fileprivate init(pipeTestEnd: FileDescriptor) {
        self.state = NIOLockedValueBox(State(pipeTestEnd: pipeTestEnd))
        self.connection = .pipe
    }

    /// Runs the peer's work and records what it produced. This is called on the peer thread.
    fileprivate func run(
        _ body: @Sendable (FIFOPeer<Output>) throws -> Output,
        workItemState: NIOThreadPool.WorkItemState
    ) {
        // This thread belongs to the peer's own thread pool, so this doesn't affect anything else.
        blockSIGPIPEOnThisThread()

        let outcome: Result<Output, any Error>
        switch workItemState {
        case .active:
            outcome = Result { try body(self) }
        case .cancelled:
            outcome = .failure(CancellationError())
        }
        self.state.withLockedValue { $0.outcome = outcome }
    }

    // MARK: Peer side: these block, so only call them from the peer thread.

    /// Blocks until the test calls ``release()``.
    ///
    /// The peer is only released once: after that, this returns immediately.
    func waitForRelease(timeout: TimeAmount = .seconds(30)) throws {
        let timeoutSeconds = Double(timeout.nanoseconds) / 1_000_000_000
        guard self.released.lock(whenValue: true, timeoutSeconds: timeoutSeconds) else {
            throw FIFOPeerError.timedOut("waiting for the test to release the peer")
        }
        self.released.unlock()
    }

    /// Blocks until the test has finished. For a pipe, the pipe's original descriptor for the test's end has
    /// been closed by then.
    func waitForTestToFinish(timeout: TimeAmount = .seconds(30)) throws {
        let timeoutSeconds = Double(timeout.nanoseconds) / 1_000_000_000
        guard self.testFinished.lock(whenValue: true, timeoutSeconds: timeoutSeconds) else {
            throw FIFOPeerError.timedOut("waiting for the test to finish")
        }
        self.testFinished.unlock()
    }

    /// Tells the test that the peer has reached a point it is waiting for.
    func reachMilestone() {
        self.state.withLockedValue { $0.milestones += 1 }
    }

    /// Blocks until the FIFO is full, so that writing to it blocks.
    ///
    /// The peer must already have opened the FIFO for reading. There's no event for a FIFO becoming full, so
    /// this polls a spare non-blocking descriptor for writing to it, which is writable until the FIFO is full.
    func waitForFIFOToFill(timeout: TimeAmount = .seconds(10)) throws {
        guard case .fifo(let path) = self.connection else {
            preconditionFailure("Only the peer of a FIFO can wait for it to fill")
        }

        // This never writes: it only stands in for the test's descriptor, which is writing.
        let spare = try FileDescriptor.open(path, .writeOnly, options: .nonBlocking)
        defer { try? spare.close() }

        let deadline = NIODeadline.now() + timeout
        while true {
            // We set a timeout on `poll` to 0 becuase we are waiting for this fd to become _not_
            // readable, and we can't set a timeout for that.
            var pollDescriptor = pollfd(fd: spare.rawValue, events: Int16(POLLOUT), revents: 0)
            if poll(&pollDescriptor, 1, 0) < 0 {
                guard errno == EINTR else {
                    throw FIFOPeerError.posix(call: "poll", errno: errno)
                }
            } else if pollDescriptor.revents & Int16(POLLOUT) == 0 {
                return
            }

            if self.testFinished.value {
                throw FIFOPeerError.testFinishedFirst("the FIFO filled up")
            }
            if NIODeadline.now() > deadline {
                throw FIFOPeerError.timedOut("waiting for the FIFO to fill up")
            }
            usleep(1000)
        }
    }

    enum OpenMode {
        case read
        case write
    }

    /// Opens the FIFO and runs `body` with the descriptor, then closes it.
    ///
    /// The FIFO is opened with a blocking `open(2)`: this blocks until the other end is opened.
    func withOpenFIFO<Result>(_ mode: OpenMode, _ body: (FileDescriptor) throws -> Result) throws -> Result {
        let descriptor = try self.openFIFO(mode)
        defer { try? descriptor.close() }
        return try body(descriptor)
    }

    private func openFIFO(_ mode: OpenMode) throws -> FileDescriptor {
        guard case .fifo(let path) = self.connection else {
            preconditionFailure("The peer of a pipe is given its end of the pipe")
        }

        switch mode {
        case .read:
            return try FileDescriptor.open(path, .readOnly)
        case .write:
            let descriptor = try FileDescriptor.open(path, .writeOnly)
            do {
                try disableSIGPIPE(descriptor)
            } catch {
                try? descriptor.close()
                throw error
            }
            return descriptor
        }
    }

    /// Writes all of `buffer`, blocking as required.
    func writeAll(_ descriptor: FileDescriptor, _ buffer: ByteBuffer) throws {
        try descriptor.writeAll(buffer.readableBytesView)
    }

    /// Reads until end-of-file, blocking as required.
    func readToEOF(_ descriptor: FileDescriptor) throws -> ByteBuffer {
        var buffer = ByteBuffer()
        while true {
            let bytesRead = try buffer.writeWithUnsafeMutableBytes(minimumWritableBytes: 4096) { bytes in
                try descriptor.read(into: bytes)
            }
            if bytesRead == 0 {
                return buffer
            }
        }
    }

    // MARK: Test side: these never block a thread.

    /// Lets the peer continue past a call to ``waitForRelease(timeout:)``.
    func release() {
        self.released.lock()
        self.released.unlock(withValue: true)
    }

    /// Suspends until the peer reaches a milestone.
    func waitForMilestone(timeout: TimeAmount = .seconds(10)) async throws {
        let deadline = NIODeadline.now() + timeout
        while true {
            let reached = self.state.withLockedValue { state -> Bool in
                if state.milestones > 0 {
                    state.milestones -= 1
                    return true
                }
                return false
            }
            if reached {
                return
            }
            if self.state.withLockedValue({ $0.outcome != nil }) {
                throw FIFOPeerError.finishedEarly
            }
            if NIODeadline.now() > deadline {
                throw FIFOPeerError.timedOut("waiting for the peer to reach a milestone")
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Whether the peer has finished.
    fileprivate var hasFinished: Bool {
        self.state.withLockedValue { $0.outcome != nil }
    }

    /// Suspends until the peer has finished and returns what it produced.
    ///
    /// This throws if the peer doesn't finish in a timely fashion.
    fileprivate func waitForOutcome(timeout: TimeAmount = .seconds(5)) async throws -> Output {
        let deadline = NIODeadline.now() + timeout
        while true {
            if let outcome = self.state.withLockedValue({ $0.outcome }) {
                return try outcome.get()
            }
            if NIODeadline.now() > deadline {
                throw FIFOPeerError.timedOut("waiting for the peer to finish")
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Unblocks the peer, however it is stuck, and waits for it to finish.
    ///
    /// This gives up waiting if the peer doesn't finish in a timely fashion.
    fileprivate func abort() async {
        // Let the peer continue past any wait for the test, now and in future.
        self.release()

        // The peer of a pipe can't be stuck opening it. Once the test's end of the pipe is closed, which
        // has already happened, the peer can't be stuck reading or writing it either. The peer of a FIFO
        // may be stuck in a blocking `open`: unblock it by briefly opening the other end of the FIFO
        // ourselves. This is retried: the peer might not have reached its `open` yet.
        let deadline = NIODeadline.now() + .seconds(10)
        while self.state.withLockedValue({ $0.outcome == nil }), NIODeadline.now() < deadline {
            if case .fifo(let path) = self.connection,
                let descriptor = try? FileDescriptor.open(path, .readWrite, options: .nonBlocking)
            {
                try? descriptor.close()
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Called once the test has finished, whether or not it succeeded.
    ///
    /// For a pipe, this closes the pipe's original descriptor for the test's end, so that the peer sees the
    /// end of the pipe once the test has closed its own descriptor. Then it lets the peer continue past
    /// ``waitForTestToFinish(timeout:)``.
    fileprivate func testDidFinish() {
        let descriptor = self.state.withLockedValue { state -> FileDescriptor? in
            defer { state.pipeTestEnd = nil }
            return state.pipeTestEnd
        }
        try? descriptor?.close()

        self.testFinished.lock()
        self.testFinished.unlock(withValue: true)
    }
}

extension XCTestCase {
    /// Creates a FIFO called `fifo` inside a new temporary directory which is removed when the test finishes.
    func makeTemporaryFIFO() async throws -> FilePath {
        let directory = try await FileSystem.shared.createTemporaryDirectory(template: "test-XXX")
        self.addTeardownBlock {
            try await FileSystem.shared.removeItem(at: directory, recursively: true)
        }

        let fifoPath = FilePath(directory).appending("fifo")
        try makeFIFO(at: fifoPath)
        return fifoPath
    }
}

/// Creates a FIFO at `path`.
func makeFIFO(at path: FilePath) throws {
    guard mkfifo(path.string, 0o644) == 0 else {
        throw FIFOPeerError.posix(call: "mkfifo", errno: errno)
    }
}

#if canImport(Darwin)
/// A pseudo-terminal: what's written to it can be read from its terminal device.
struct PseudoTerminal: Sendable {
    /// The path of the terminal device.
    let path: FilePath

    /// The controlling side of the pseudo-terminal.
    fileprivate let controller: FileDescriptor

    /// Writes all of `buffer` to the terminal's input.
    func write(_ buffer: ByteBuffer) throws {
        try self.controller.writeAll(buffer.readableBytesView)
    }
}

/// Creates a pseudo-terminal and runs `body` with it, then closes it.
///
/// Glibc only declares the functions which create a pseudo-terminal for X/Open applications, and so they aren't
/// available to Swift: this is only available on Darwin.
func withPseudoTerminal<Result>(_ body: (PseudoTerminal) async throws -> Result) async throws -> Result {
    let rawController = posix_openpt(O_RDWR | O_NOCTTY)
    guard rawController >= 0 else {
        throw FIFOPeerError.posix(call: "posix_openpt", errno: errno)
    }
    let controller = FileDescriptor(rawValue: rawController)
    defer { try? controller.close() }

    guard grantpt(rawController) == 0 else {
        throw FIFOPeerError.posix(call: "grantpt", errno: errno)
    }
    guard unlockpt(rawController) == 0 else {
        throw FIFOPeerError.posix(call: "unlockpt", errno: errno)
    }
    guard let name = ptsname(rawController) else {
        throw FIFOPeerError.posix(call: "ptsname", errno: errno)
    }
    let path = FilePath(String(cString: name))

    // Hold the terminal open while `body` runs, with echo turned off. Otherwise what's written to the terminal
    // is echoed back to the controlling side, where nothing reads it, and closing the terminal waits more than
    // half a second for it to drain. Holding the terminal open also stops its settings being reset when the
    // test opens it.
    let terminal = try FileDescriptor.open(
        path,
        .readWrite,
        options: FileDescriptor.OpenOptions(rawValue: O_NOCTTY)
    )
    defer { try? terminal.close() }

    var attributes = termios()
    guard tcgetattr(terminal.rawValue, &attributes) == 0 else {
        throw FIFOPeerError.posix(call: "tcgetattr", errno: errno)
    }
    attributes.c_lflag &= ~tcflag_t(ECHO)
    guard tcsetattr(terminal.rawValue, TCSANOW, &attributes) == 0 else {
        throw FIFOPeerError.posix(call: "tcsetattr", errno: errno)
    }

    return try await body(PseudoTerminal(path: path, controller: controller))
}
#endif
#endif  // !os(Windows)
