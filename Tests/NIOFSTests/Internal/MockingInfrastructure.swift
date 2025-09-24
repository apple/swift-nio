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

//This source file is part of the Swift System open source project
//
//Copyright (c) 2020 Apple Inc. and the Swift System project authors
//Licensed under Apache License v2.0 with Runtime Library Exception
//
//See https://swift.org/LICENSE.txt for license information

@_spi(Testing) import NIOFS
import SystemPackage
import XCTest

#if ENABLE_MOCKING
internal struct Wildcard: Hashable {}

extension Trace.Entry {
    /// This implements `==` with wildcard matching.
    /// (`Entry` cannot conform to `Equatable`/`Hashable` this way because
    /// the wildcard matching `==` relation isn't transitive.)
    internal func matches(_ other: Self) -> Bool {
        guard self.name == other.name else { return false }
        guard self.arguments.count == other.arguments.count else { return false }
        for i in self.arguments.indices {
            if self.arguments[i] is Wildcard || other.arguments[i] is Wildcard {
                continue
            }
            guard self.arguments[i] == other.arguments[i] else { return false }
        }
        return true
    }
}

internal protocol TestCase {
    // TODO: want a source location stack, more fidelity, kinds of stack entries, etc
    var file: StaticString { get }
    var line: UInt { get }

    // TODO: Instead have an attribute to register a test in a allTests var, similar to the argument parser.
    func runAllTests()

    // Customization hook: add adornment to reported failure reason
    // Defaut: reason or empty
    func failureMessage(_ reason: String?) -> String
}

extension TestCase {
    // Default implementation
    func failureMessage(_ reason: String?) -> String { reason ?? "" }

    func expectEqualSequence<S1: Sequence, S2: Sequence>(
        _ expected: S1,
        _ actual: S2,
        _ message: String? = nil
    ) where S1.Element: Equatable, S1.Element == S2.Element {
        if !expected.elementsEqual(actual) {
            defer { print("expected: \(expected)\n  actual: \(actual)") }
            fail(message)
        }
    }
    func expectEqual<E: Equatable>(
        _ expected: E,
        _ actual: E,
        _ message: String? = nil
    ) {
        if actual != expected {
            defer { print("expected: \(expected)\n  actual: \(actual)") }
            fail(message)
        }
    }
    func expectNotEqual<E: Equatable>(
        _ expected: E,
        _ actual: E,
        _ message: String? = nil
    ) {
        if actual == expected {
            defer { print("expected not equal: \(expected) and \(actual)") }
            fail(message)
        }
    }
    func expectMatch(
        _ expected: Trace.Entry?,
        _ actual: Trace.Entry?,
        _ message: String? = nil
    ) {
        func check() -> Bool {
            switch (expected, actual) {
            case let (expected?, actual?):
                return expected.matches(actual)
            case (nil, nil):
                return true
            default:
                return false
            }
        }
        if !check() {
            let e = expected.map { "\($0)" } ?? "nil"
            let a = actual.map { "\($0)" } ?? "nil"
            defer { print("expected: \(e)\n  actual: \(a)") }
            fail(message)
        }
    }
    func expectNil<T>(
        _ actual: T?,
        _ message: String? = nil
    ) {
        if actual != nil {
            defer { print("expected nil: \(actual!)") }
            fail(message)
        }
    }
    func expectNotNil<T>(
        _ actual: T?,
        _ message: String? = nil
    ) {
        if actual == nil {
            defer { print("expected non-nil") }
            fail(message)
        }
    }
    func expectTrue(
        _ actual: Bool,
        _ message: String? = nil
    ) {
        if !actual { fail(message) }
    }
    func expectFalse(
        _ actual: Bool,
        _ message: String? = nil
    ) {
        if actual { fail(message) }
    }

    func fail(_ reason: String? = nil) {
        XCTAssert(false, failureMessage(reason), file: file, line: line)
    }
}

internal struct MockTestCase: TestCase {
    var file: StaticString
    var line: UInt

    var expected: Trace.Entry
    var interruptBehavior: InterruptBehavior

    var interruptable: Bool { interruptBehavior == .interruptable }

    internal enum InterruptBehavior {
        // Retry the syscall on EINTR
        case interruptable

        // Cannot return EINTR
        case noInterrupt

        // Cannot error at all
        case noError
    }

    var body: (_ retryOnInterrupt: Bool) throws -> Void

    init(
        _ file: StaticString = #file,
        _ line: UInt = #line,
        name: String,
        _ interruptable: InterruptBehavior,
        _ args: AnyHashable...,
        body: @escaping (_ retryOnInterrupt: Bool) throws -> Void
    ) {
        self.file = file
        self.line = line
        self.expected = Trace.Entry(name: name, args)
        self.interruptBehavior = interruptable
        self.body = body
    }

    func runAllTests() {
        XCTAssertFalse(MockingDriver.enabled)
        MockingDriver.withMockingEnabled { mocking in
            // Make sure we completely match the trace queue
            self.expectTrue(mocking.trace.isEmpty)
            defer { self.expectTrue(mocking.trace.isEmpty) }

            // Test our API mappings to the lower-level syscall invocation
            do {
                try body(true)
                self.expectMatch(self.expected, mocking.trace.dequeue())
            } catch {
                self.fail()
            }

            // Non-error-ing syscalls shouldn't ever throw
            guard interruptBehavior != .noError else {
                do {
                    try body(interruptable)
                    self.expectMatch(self.expected, mocking.trace.dequeue())
                    try body(!interruptable)
                    self.expectMatch(self.expected, mocking.trace.dequeue())
                } catch {
                    self.fail()
                }
                return
            }

            // Test interupt behavior. Interruptable calls will be told not to
            // retry to catch the EINTR. Non-interruptable calls will be told to
            // retry, to make sure they don't spin (e.g. if API changes to include
            // interruptable)
            do {
                mocking.forceErrno = .always(errno: EINTR)
                try body(!interruptable)
                self.fail()
            } catch Errno.interrupted {
                // Success!
                self.expectMatch(self.expected, mocking.trace.dequeue())
            } catch {
                self.fail()
            }

            // Force a limited number of EINTRs, and make sure interruptable functions
            // retry that number of times. Non-interruptable functions should throw it.
            do {
                mocking.forceErrno = .counted(errno: EINTR, count: 3)

                try body(interruptable)
                self.expectMatch(self.expected, mocking.trace.dequeue())  // EINTR
                self.expectMatch(self.expected, mocking.trace.dequeue())  // EINTR
                self.expectMatch(self.expected, mocking.trace.dequeue())  // EINTR
                self.expectMatch(self.expected, mocking.trace.dequeue())  // Success
            } catch Errno.interrupted {
                self.expectFalse(interruptable)
                self.expectMatch(self.expected, mocking.trace.dequeue())  // EINTR
            } catch {
                self.fail()
            }
        }
    }
}

internal func withWindowsPaths(enabled: Bool, _ body: () -> Void) {
    _withWindowsPaths(enabled: enabled, body)
}
#endif
