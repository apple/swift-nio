//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2025 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Dispatch
import NIOConcurrencyHelpers
import NIOCore
import XCTest

@testable import NIOPosix

class ThreadTest: XCTestCase {
    func testCurrentThreadWorks() {
        let s = DispatchSemaphore(value: 0)
        let thread = NIOLockedValueBox<NIOThread?>(nil)
        defer {
            Self.joinThread(thread)
        }
        NIOThread.spawnAndRun { t in
            XCTAssertTrue(t.isCurrentSlow)
            thread.withLockedValue { thread in
                thread = t
            }
            s.signal()
        }
        s.wait()
    }

    func testCurrentThreadIsNotTrueOnOtherThread() {
        let s = DispatchSemaphore(value: 0)
        let thread1 = NIOLockedValueBox<NIOThread?>(nil)
        defer {
            Self.joinThread(thread1)
        }
        let thread2 = NIOLockedValueBox<NIOThread?>(nil)
        defer {
            Self.joinThread(thread2)
        }
        NIOThread.spawnAndRun { t1 in
            NIOThread.spawnAndRun { t2 in
                XCTAssertFalse(t1.isCurrentSlow)
                XCTAssertTrue(t2.isCurrentSlow)
                thread1.withLockedValue { thread in
                    thread = t1
                }
                thread2.withLockedValue { thread in
                    thread = t2
                }
                s.signal()
            }
        }
        s.wait()
    }

    func testThreadSpecificsAreNilWhenNotPresent() {
        class SomeClass {}
        let s = DispatchSemaphore(value: 0)
        let thread = NIOLockedValueBox<NIOThread?>(nil)
        defer {
            Self.joinThread(thread)
        }
        NIOThread.spawnAndRun { t in
            let tsv: ThreadSpecificVariable<SomeClass> = ThreadSpecificVariable()
            XCTAssertNil(tsv.currentValue)
            thread.withLockedValue { thread in
                thread = t
            }
            s.signal()
        }
        s.wait()
    }

    func testThreadSpecificsWorks() {
        class SomeClass {}
        let s = DispatchSemaphore(value: 0)
        let thread = NIOLockedValueBox<NIOThread?>(nil)
        defer {
            Self.joinThread(thread)
        }
        NIOThread.spawnAndRun { t in
            thread.withLockedValue { thread in
                thread = t
            }
            let tsv: ThreadSpecificVariable<SomeClass> = ThreadSpecificVariable()
            XCTAssertNil(tsv.currentValue)
            let expected = SomeClass()
            tsv.currentValue = expected
            XCTAssert(expected === tsv.currentValue)
            s.signal()
        }
        s.wait()
    }

    func testThreadSpecificsAreNotAvailableOnADifferentThread() {
        class SomeClass {}
        let s = DispatchSemaphore(value: 0)
        let thread1 = NIOLockedValueBox<NIOThread?>(nil)
        defer {
            Self.joinThread(thread1)
        }
        let thread2 = NIOLockedValueBox<NIOThread?>(nil)
        defer {
            Self.joinThread(thread2)
        }
        NIOThread.spawnAndRun { t1 in
            let tsv = ThreadSpecificVariable<SomeClass>()
            XCTAssertNil(tsv.currentValue)
            tsv.currentValue = SomeClass()
            XCTAssertNotNil(tsv.currentValue)
            NIOThread.spawnAndRun { t2 in
                XCTAssertNil(tsv.currentValue)
                thread1.withLockedValue { thread in
                    thread = t1
                }
                thread2.withLockedValue { thread in
                    thread = t2
                }
                s.signal()
            }
        }
        s.wait()
    }

    func testThreadSpecificDoesNotLeakIfThreadExitsWhilstSet() {
        let s = DispatchSemaphore(value: 0)
        let thread = NIOLockedValueBox<NIOThread?>(nil)
        defer {
            Self.joinThread(thread)
        }
        class SomeClass {
            let s: DispatchSemaphore
            init(sem: DispatchSemaphore) { self.s = sem }
            deinit {
                s.signal()
            }
        }
        weak var weakSome: SomeClass? = nil
        NIOThread.spawnAndRun { t in
            let some = SomeClass(sem: s)
            weakSome = some
            let tsv = ThreadSpecificVariable<SomeClass>()
            thread.withLockedValue { thread in
                thread = t
            }
            tsv.currentValue = some
            XCTAssertNotNil(tsv.currentValue)
        }
        s.wait()
        XCTAssertNil(weakSome)
    }

    func testThreadSpecificDoesNotLeakIfThreadExitsAfterUnset() {
        let s = DispatchSemaphore(value: 0)
        let thread = NIOLockedValueBox<NIOThread?>(nil)
        defer {
            Self.joinThread(thread)
        }
        class SomeClass {
            let s: DispatchSemaphore
            init(sem: DispatchSemaphore) { self.s = sem }
            deinit {
                s.signal()
            }
        }
        weak var weakSome: SomeClass? = nil
        NIOThread.spawnAndRun { t in
            thread.withLockedValue { thread in
                thread = t
            }
            let some = SomeClass(sem: s)
            weakSome = some
            let tsv = ThreadSpecificVariable<SomeClass>()
            tsv.currentValue = some
            XCTAssertNotNil(tsv.currentValue)
            tsv.currentValue = nil
        }
        s.wait()
        XCTAssertNil(weakSome)
    }

    func testThreadSpecificDoesNotLeakIfReplacedWithNewValue() {
        let s1 = DispatchSemaphore(value: 0)
        let s2 = DispatchSemaphore(value: 0)
        let s3 = DispatchSemaphore(value: 0)
        let thread = NIOLockedValueBox<NIOThread?>(nil)
        defer {
            Self.joinThread(thread)
        }
        class SomeClass {
            let s: DispatchSemaphore
            init(sem: DispatchSemaphore) { self.s = sem }
            deinit {
                s.signal()
            }
        }
        weak var weakSome1: SomeClass? = nil
        weak var weakSome2: SomeClass? = nil
        weak var weakSome3: SomeClass? = nil
        NIOThread.spawnAndRun { t in
            thread.withLockedValue { thread in
                thread = t
            }
            let some1 = SomeClass(sem: s1)
            weakSome1 = some1
            let some2 = SomeClass(sem: s2)
            weakSome2 = some2
            let some3 = SomeClass(sem: s3)
            weakSome3 = some3

            let tsv = ThreadSpecificVariable<SomeClass>()
            tsv.currentValue = some1
            XCTAssertNotNil(tsv.currentValue)
            tsv.currentValue = some2
            XCTAssertNotNil(tsv.currentValue)
            tsv.currentValue = some3
            XCTAssertNotNil(tsv.currentValue)
        }
        s1.wait()
        s2.wait()
        s3.wait()
        XCTAssertNil(weakSome1)
        XCTAssertNil(weakSome2)
        XCTAssertNil(weakSome3)
    }

    func testSharingThreadSpecificVariableWorks() {
        let s = DispatchSemaphore(value: 0)
        let thread1 = NIOLockedValueBox<NIOThread?>(nil)
        defer {
            Self.joinThread(thread1)
        }
        let threads = NIOLockedValueBox<[NIOThread]>([])
        defer {
            for thread in threads.withLockedValue({ $0 }) {
                thread.join()
            }
        }
        class SomeClass {
            let s: DispatchSemaphore
            init(sem: DispatchSemaphore) { self.s = sem }
            deinit {
                s.signal()
            }
        }
        weak var weakSome: SomeClass? = nil
        NIOThread.spawnAndRun { t1 in
            thread1.withLockedValue { thread in
                thread = t1
            }
            let some = SomeClass(sem: s)
            weakSome = some
            let tsv = ThreadSpecificVariable<SomeClass>()
            for _ in 0..<10 {
                NIOThread.spawnAndRun { t in
                    threads.withLockedValue { threads in
                        threads.append(t)
                    }
                    tsv.currentValue = some
                }
            }
        }
        s.wait()
        XCTAssertNil(weakSome)
    }

    func testThreadSpecificInitWithValueWorks() throws {
        class SomeClass {}
        let tsv = ThreadSpecificVariable(value: SomeClass())
        XCTAssertNotNil(tsv.currentValue)
    }

    func testThreadSpecificDoesNotLeakWhenOutOfScopeButThreadStillRunning() {
        let s = DispatchSemaphore(value: 0)
        let thread = NIOLockedValueBox<NIOThread?>(nil)
        defer {
            Self.joinThread(thread)
        }
        class SomeClass {
            let s: DispatchSemaphore
            init(sem: DispatchSemaphore) { self.s = sem }
            deinit {
                s.signal()
            }
        }
        weak var weakSome: SomeClass? = nil
        weak var weakTSV: ThreadSpecificVariable<SomeClass>? = nil
        NIOThread.spawnAndRun { t in
            thread.withLockedValue { thread in
                thread = t
            }
            {
                let some = SomeClass(sem: s)
                weakSome = some
                let tsv = ThreadSpecificVariable<SomeClass>()
                weakTSV = tsv
                tsv.currentValue = some
                XCTAssertNotNil(tsv.currentValue)
                XCTAssertNotNil(weakTSV)
            }()
        }
        s.wait()
        assert(weakSome == nil, within: .seconds(1))
        assert(weakTSV == nil, within: .seconds(1))
    }

    func testThreadSpecificDoesNotLeakIfThreadExitsWhilstSetOnMultipleThreads() {
        let numberOfThreads = 6
        let s = DispatchSemaphore(value: 0)
        let threads = NIOLockedValueBox<[NIOThread]>([])
        defer {
            for thread in threads.withLockedValue({ $0 }) {
                thread.join()
            }
        }
        class SomeClass {
            let s: DispatchSemaphore
            init(sem: DispatchSemaphore) { self.s = sem }
            deinit {
                s.signal()
            }
        }

        for _ in 0..<numberOfThreads {
            NIOThread.spawnAndRun { t in
                threads.withLockedValue { threads in
                    threads.append(t)
                }
                let some = SomeClass(sem: s)
                let tsv = ThreadSpecificVariable<SomeClass>()
                tsv.currentValue = some
                XCTAssertNotNil(tsv.currentValue)
            }
        }

        let timeout: DispatchTime = .now() + .seconds(1)
        for _ in 0..<numberOfThreads {
            switch s.wait(timeout: timeout) {
            case .success:
                ()
            case .timedOut:
                XCTFail("timed out")
            }
        }
    }

    func testThreadSpecificDoesNotLeakWhenOutOfScopeButSetOnMultipleThreads() {
        let t1Sem = DispatchSemaphore(value: 0)
        let t2Sem = DispatchSemaphore(value: 0)
        let thread1 = NIOLockedValueBox<NIOThread?>(nil)
        defer {
            Self.joinThread(thread1)
        }
        let thread2 = NIOLockedValueBox<NIOThread?>(nil)
        defer {
            Self.joinThread(thread2)
        }
        class SomeClass {
            let s: DispatchSemaphore
            init(sem: DispatchSemaphore) { self.s = sem }
            deinit {
                s.signal()
            }
        }
        var globalTSVs: [ThreadSpecificVariable<SomeClass>] = []
        let globalTSVLock = NIOLock()
        ({
            let tsv = ThreadSpecificVariable<SomeClass>()
            globalTSVLock.withLock {
                globalTSVs.append(tsv)
                globalTSVs.append(tsv)
            }
        })()

        weak var weakSome1: SomeClass? = nil
        weak var weakSome2: SomeClass? = nil
        weak var weakTSV: ThreadSpecificVariable<SomeClass>? = nil
        NIOThread.spawnAndRun { t1 in
            thread1.withLockedValue { thread in
                thread = t1
            }
            {
                let some = SomeClass(sem: t1Sem)
                weakSome1 = some
                var tsv: ThreadSpecificVariable<SomeClass>!
                globalTSVLock.withLock {
                    tsv = globalTSVs.removeFirst()
                }
                weakTSV = tsv
                tsv.currentValue = some
                XCTAssertNotNil(tsv.currentValue)
                XCTAssertNotNil(weakTSV)
            }()
        }
        NIOThread.spawnAndRun { t2 in
            thread2.withLockedValue { thread in
                thread = t2
            }
            {
                let some = SomeClass(sem: t2Sem)
                weakSome2 = some
                var tsv: ThreadSpecificVariable<SomeClass>!
                globalTSVLock.withLock {
                    tsv = globalTSVs.removeFirst()
                }
                weakTSV = tsv
                tsv.currentValue = some
                XCTAssertNotNil(tsv.currentValue)
                XCTAssertNotNil(weakTSV)
            }()
        }
        t2Sem.wait()  // wait on the other thread's `some` deallocation
        assert(weakSome1 == nil, within: .seconds(1))
        assert(weakTSV == nil, within: .seconds(1))

        t1Sem.wait()  // wait on the other thread's `some` deallocation
        assert(weakSome2 == nil, within: .seconds(1))
        assert(weakTSV == nil, within: .seconds(1))
    }

    // MARK: - Helpers
    static func joinThread(_ thread: NIOLockedValueBox<NIOThread?>, file: StaticString = #filePath, line: UInt = #line)
    {
        if let thread = thread.withLockedValue({ $0 }) {
            thread.join()
        } else {
            XCTFail("thread unexpectedly nil", file: file, line: line)
        }
    }
}
