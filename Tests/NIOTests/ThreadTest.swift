//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import NIO
import NIOConcurrencyHelpers
import XCTest
import Dispatch

class ThreadTest: XCTestCase {
    func testCurrentThreadWorks() throws {
        let s = DispatchSemaphore(value: 0)
        Thread.spawnAndRun { t in
            XCTAssertTrue(t.isCurrent)
            s.signal()
        }
        s.wait()
    }

    func testCurrentThreadIsNotTrueOnOtherThread() throws {
        let s = DispatchSemaphore(value: 0)
        Thread.spawnAndRun { t1 in
            Thread.spawnAndRun { t2 in
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
        Thread.spawnAndRun { (_: NIO.Thread) in
            let tsv: ThreadSpecificVariable<SomeClass> = ThreadSpecificVariable()
            XCTAssertNil(tsv.currentValue)
            s.signal()
        }
        s.wait()
    }

    func testThreadSpecificsWorks() throws {
        class SomeClass {}
        let s = DispatchSemaphore(value: 0)
        Thread.spawnAndRun { (_: NIO.Thread) in
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
        Thread.spawnAndRun { (_: NIO.Thread) in
            let tsv = ThreadSpecificVariable<SomeClass>()
            XCTAssertNil(tsv.currentValue)
            tsv.currentValue = SomeClass()
            XCTAssertNotNil(tsv.currentValue)
            Thread.spawnAndRun { t2 in
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
        Thread.spawnAndRun { (_: NIO.Thread) in
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
        Thread.spawnAndRun { (_: NIO.Thread) in
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
        Thread.spawnAndRun { (_: NIO.Thread) in
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
        Thread.spawnAndRun { (_: NIO.Thread) in
            let some = SomeClass(sem: s)
            weakSome = some
            let tsv = ThreadSpecificVariable<SomeClass>()
            for _ in 0..<10 {
                Thread.spawnAndRun { (_: NIO.Thread) in
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
}
