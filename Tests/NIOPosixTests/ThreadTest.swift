//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import NIOPosix
import NIOConcurrencyHelpers
import XCTest
import Dispatch

class ThreadTest: XCTestCase {
    func testCurrentThreadWorks() throws {
        let s = DispatchSemaphore(value: 0)
        NIOThread.spawnAndRun { t in
            XCTAssertTrue(t.isCurrent)
            s.signal()
        }
        s.wait()
    }

    func testCurrentThreadIsNotTrueOnOtherThread() throws {
        let s = DispatchSemaphore(value: 0)
        NIOThread.spawnAndRun { t1 in
            NIOThread.spawnAndRun { t2 in
                XCTAssertFalse(t1.isCurrent)
                XCTAssertTrue(t2.isCurrent)
                s.signal()
            }
        }
        s.wait()
    }

    func testThreadSpecificsAreNilWhenNotPresent() throws {
        class SomeClass {}
        let s = DispatchSemaphore(value: 0)
        NIOThread.spawnAndRun { (_: NIOPosix.NIOThread) in
            let tsv: ThreadSpecificVariable<SomeClass> = ThreadSpecificVariable()
            XCTAssertNil(tsv.currentValue)
            s.signal()
        }
        s.wait()
    }

    func testThreadSpecificsWorks() throws {
        class SomeClass {}
        let s = DispatchSemaphore(value: 0)
        NIOThread.spawnAndRun { (_: NIOPosix.NIOThread) in
            let tsv: ThreadSpecificVariable<SomeClass> = ThreadSpecificVariable()
            XCTAssertNil(tsv.currentValue)
            let expected = SomeClass()
            tsv.currentValue = expected
            XCTAssert(expected === tsv.currentValue)
            s.signal()
        }
        s.wait()
    }

    func testThreadSpecificsAreNotAvailableOnADifferentThread() throws {
        class SomeClass {}
        let s = DispatchSemaphore(value: 0)
        NIOThread.spawnAndRun { (_: NIOPosix.NIOThread) in
            let tsv = ThreadSpecificVariable<SomeClass>()
            XCTAssertNil(tsv.currentValue)
            tsv.currentValue = SomeClass()
            XCTAssertNotNil(tsv.currentValue)
            NIOThread.spawnAndRun { t2 in
                XCTAssertNil(tsv.currentValue)
                s.signal()
            }
        }
        s.wait()
    }

    func testThreadSpecificDoesNotLeakIfThreadExitsWhilstSet() throws {
        let s = DispatchSemaphore(value: 0)
        class SomeClass {
            let s: DispatchSemaphore
            init(sem: DispatchSemaphore) { self.s = sem }
            deinit {
                s.signal()
            }
        }
        weak var weakSome: SomeClass? = nil
        NIOThread.spawnAndRun { (_: NIOPosix.NIOThread) in
            let some = SomeClass(sem: s)
            weakSome = some
            let tsv = ThreadSpecificVariable<SomeClass>()
            tsv.currentValue = some
            XCTAssertNotNil(tsv.currentValue)
        }
        s.wait()
        XCTAssertNil(weakSome)
    }

    func testThreadSpecificDoesNotLeakIfThreadExitsAfterUnset() throws {
        let s = DispatchSemaphore(value: 0)
        class SomeClass {
            let s: DispatchSemaphore
            init(sem: DispatchSemaphore) { self.s = sem }
            deinit {
                s.signal()
            }
        }
        weak var weakSome: SomeClass? = nil
        NIOThread.spawnAndRun { (_: NIOPosix.NIOThread) in
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

    func testThreadSpecificDoesNotLeakIfReplacedWithNewValue() throws {
        let s1 = DispatchSemaphore(value: 0)
        let s2 = DispatchSemaphore(value: 0)
        let s3 = DispatchSemaphore(value: 0)
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
        NIOThread.spawnAndRun { (_: NIOPosix.NIOThread) in
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

    func testSharingThreadSpecificVariableWorks() throws {
        let s = DispatchSemaphore(value: 0)
        class SomeClass {
            let s: DispatchSemaphore
            init(sem: DispatchSemaphore) { self.s = sem }
            deinit {
                s.signal()
            }
        }
        weak var weakSome: SomeClass? = nil
        NIOThread.spawnAndRun { (_: NIOPosix.NIOThread) in
            let some = SomeClass(sem: s)
            weakSome = some
            let tsv = ThreadSpecificVariable<SomeClass>()
            for _ in 0..<10 {
                NIOThread.spawnAndRun { (_: NIOPosix.NIOThread) in
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

    func testThreadSpecificDoesNotLeakWhenOutOfScopeButThreadStillRunning() throws {
        let s = DispatchSemaphore(value: 0)
        class SomeClass {
            let s: DispatchSemaphore
            init(sem: DispatchSemaphore) { self.s = sem }
            deinit {
                s.signal()
            }
        }
        weak var weakSome: SomeClass? = nil
        weak var weakTSV: ThreadSpecificVariable<SomeClass>? = nil
        NIOThread.spawnAndRun { (_: NIOThread) in
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

    func testThreadSpecificDoesNotLeakIfThreadExitsWhilstSetOnMultipleThreads() throws {
        let numberOfThreads = 6
        let s = DispatchSemaphore(value: 0)
        class SomeClass {
            let s: DispatchSemaphore
            init(sem: DispatchSemaphore) { self.s = sem }
            deinit {
                s.signal()
            }
        }

        for _ in 0..<numberOfThreads {
            NIOThread.spawnAndRun { (_: NIOThread) in
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

    func testThreadSpecificDoesNotLeakWhenOutOfScopeButSetOnMultipleThreads() throws {
        let t1Sem = DispatchSemaphore(value: 0)
        let t2Sem = DispatchSemaphore(value: 0)
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
        NIOThread.spawnAndRun { (_: NIOThread) in
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
        NIOThread.spawnAndRun { (_: NIOThread) in
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
        t2Sem.wait() /* wait on the other thread's `some` deallocation */
        assert(weakSome1 == nil, within: .seconds(1))
        assert(weakTSV == nil, within: .seconds(1))

        t1Sem.wait() /* wait on the other thread's `some` deallocation */
        assert(weakSome2 == nil, within: .seconds(1))
        assert(weakTSV == nil, within: .seconds(1))
    }
}
