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
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#else
import Glibc
#endif
import Dispatch
import XCTest
@testable import NIOConcurrencyHelpers

class NIOConcurrencyHelpersTests: XCTestCase {
    private func sumOfIntegers(until n: UInt64) -> UInt64 {
        return n*(n+1)/2
    }

    func testLargeContendedAtomicSum() {
        let noAsyncs: UInt64 = 64
        let noCounts: UInt64 = 200_000

        let q = DispatchQueue(label: "q", attributes: .concurrent)
        let g = DispatchGroup()
        let ai = NIOConcurrencyHelpers.Atomic<UInt64>(value: 0)
        for thread in 1...noAsyncs {
            q.async(group: g) {
                for _ in 0..<noCounts {
                    _ = ai.add(thread)
                }
            }
        }
        g.wait()
        XCTAssertEqual(sumOfIntegers(until: noAsyncs) * noCounts, ai.load())
    }

    func testCompareAndExchangeBool() {
        let ab = Atomic<Bool>(value: true)

        XCTAssertFalse(ab.compareAndExchange(expected: false, desired: false))
        XCTAssertTrue(ab.compareAndExchange(expected: true, desired: true))

        XCTAssertFalse(ab.compareAndExchange(expected: false, desired: false))
        XCTAssertTrue(ab.compareAndExchange(expected: true, desired: false))

        XCTAssertTrue(ab.compareAndExchange(expected: false, desired: false))
        XCTAssertTrue(ab.compareAndExchange(expected: false, desired: true))
    }

    func testAllOperationsBool() {
        let ab = Atomic<Bool>(value: false)
        XCTAssertEqual(false, ab.load())
        ab.store(false)
        XCTAssertEqual(false, ab.load())
        ab.store(true)
        XCTAssertEqual(true, ab.load())
        ab.store(true)
        XCTAssertEqual(true, ab.load())
        XCTAssertEqual(true, ab.exchange(with: true))
        XCTAssertEqual(true, ab.exchange(with: false))
        XCTAssertEqual(false, ab.exchange(with: false))
        XCTAssertTrue(ab.compareAndExchange(expected: false, desired: true))
        XCTAssertFalse(ab.compareAndExchange(expected: false, desired: true))
    }

    func testCompareAndExchangeUInts() {
        func testFor<T: AtomicPrimitive & FixedWidthInteger & UnsignedInteger>(_ value: T.Type) {
            let zero: T = 0
            let max = ~zero

            let ab = Atomic<T>(value: max)

            XCTAssertFalse(ab.compareAndExchange(expected: zero, desired: zero))
            XCTAssertTrue(ab.compareAndExchange(expected: max, desired: max))

            XCTAssertFalse(ab.compareAndExchange(expected: zero, desired: zero))
            XCTAssertTrue(ab.compareAndExchange(expected: max, desired: zero))

            XCTAssertTrue(ab.compareAndExchange(expected: zero, desired: zero))
            XCTAssertTrue(ab.compareAndExchange(expected: zero, desired: max))

            var counter = max
            for _ in 0..<255 {
                XCTAssertTrue(ab.compareAndExchange(expected: counter, desired: counter-1))
                counter = counter - 1
            }
        }

        testFor(UInt8.self)
        testFor(UInt16.self)
        testFor(UInt32.self)
        testFor(UInt64.self)
        testFor(UInt.self)
    }

    func testCompareAndExchangeInts() {
        func testFor<T: AtomicPrimitive & FixedWidthInteger & SignedInteger>(_ value: T.Type) {
            let zero: T = 0
            let upperBound: T = 127

            let ab = Atomic<T>(value: upperBound)

            XCTAssertFalse(ab.compareAndExchange(expected: zero, desired: zero))
            XCTAssertTrue(ab.compareAndExchange(expected: upperBound, desired: upperBound))

            XCTAssertFalse(ab.compareAndExchange(expected: zero, desired: zero))
            XCTAssertTrue(ab.compareAndExchange(expected: upperBound, desired: zero))

            XCTAssertTrue(ab.compareAndExchange(expected: zero, desired: zero))
            XCTAssertTrue(ab.compareAndExchange(expected: zero, desired: upperBound))

            var counter = upperBound
            for _ in 0..<255 {
                XCTAssertTrue(ab.compareAndExchange(expected: counter, desired: counter-1))
                XCTAssertFalse(ab.compareAndExchange(expected: counter, desired: counter))
                counter = counter - 1
            }
        }

        testFor(Int8.self)
        testFor(Int16.self)
        testFor(Int32.self)
        testFor(Int64.self)
        testFor(Int.self)
    }

    func testAddSub() {
        func testFor<T: AtomicPrimitive & FixedWidthInteger>(_ value: T.Type) {
            let zero: T = 0

            let ab = Atomic<T>(value: zero)

            XCTAssertEqual(0, ab.add(1))
            XCTAssertEqual(1, ab.add(41))
            XCTAssertEqual(42, ab.add(23))

            XCTAssertEqual(65, ab.load())

            XCTAssertEqual(65, ab.sub(23))
            XCTAssertEqual(42, ab.sub(41))
            XCTAssertEqual(1, ab.sub(1))

            XCTAssertEqual(0, ab.load())
        }

        testFor(Int8.self)
        testFor(Int16.self)
        testFor(Int32.self)
        testFor(Int64.self)
        testFor(Int.self)
        testFor(UInt8.self)
        testFor(UInt16.self)
        testFor(UInt32.self)
        testFor(UInt64.self)
        testFor(UInt.self)
    }

    func testExchange() {
        func testFor<T: AtomicPrimitive & FixedWidthInteger>(_ value: T.Type) {
            let zero: T = 0

            let ab = Atomic<T>(value: zero)

            XCTAssertEqual(0, ab.exchange(with: 1))
            XCTAssertEqual(1, ab.exchange(with: 42))
            XCTAssertEqual(42, ab.exchange(with: 65))

            XCTAssertEqual(65, ab.load())

            XCTAssertEqual(65, ab.exchange(with: 42))
            XCTAssertEqual(42, ab.exchange(with: 1))
            XCTAssertEqual(1, ab.exchange(with: 0))

            XCTAssertEqual(0, ab.load())
        }

        testFor(Int8.self)
        testFor(Int16.self)
        testFor(Int32.self)
        testFor(Int64.self)
        testFor(Int.self)
        testFor(UInt8.self)
        testFor(UInt16.self)
        testFor(UInt32.self)
        testFor(UInt64.self)
        testFor(UInt.self)
    }

    func testLoadStore() {
        func testFor<T: AtomicPrimitive & FixedWidthInteger>(_ value: T.Type) {
            let zero: T = 0

            let ab = Atomic<T>(value: zero)

            XCTAssertEqual(0, ab.load())
            ab.store(42)
            XCTAssertEqual(42, ab.load())
            ab.store(0)
            XCTAssertEqual(0, ab.load())
        }

        testFor(Int8.self)
        testFor(Int16.self)
        testFor(Int32.self)
        testFor(Int64.self)
        testFor(Int.self)
        testFor(UInt8.self)
        testFor(UInt16.self)
        testFor(UInt32.self)
        testFor(UInt64.self)
        testFor(UInt.self)
    }

    func testLockMutualExclusion() {
        let l = Lock()

        var x = 1
        let q = DispatchQueue(label: "q")
        let g = DispatchGroup()
        let sem1 = DispatchSemaphore(value: 0)
        let sem2 = DispatchSemaphore(value: 0)

        l.lock()

        q.async(group: g) {
            sem1.signal()
            l.lock()
            x = 2
            l.unlock()
            sem2.signal()
        }

        sem1.wait()
        XCTAssertEqual(DispatchTimeoutResult.timedOut,
                       g.wait(timeout: .now() + 0.1))
        XCTAssertEqual(1, x)

        l.unlock()
        sem2.wait()

        l.lock()
        XCTAssertEqual(2, x)
        l.unlock()
    }

    func testWithLockMutualExclusion() {
        let l = Lock()

        var x = 1
        let q = DispatchQueue(label: "q")
        let g = DispatchGroup()
        let sem1 = DispatchSemaphore(value: 0)
        let sem2 = DispatchSemaphore(value: 0)

        l.withLock {
            q.async(group: g) {
                sem1.signal()
                l.withLock {
                    x = 2
                }
                sem2.signal()
            }

            sem1.wait()
            XCTAssertEqual(DispatchTimeoutResult.timedOut,
                           g.wait(timeout: .now() + 0.1))
            XCTAssertEqual(1, x)
        }
        sem2.wait()

        l.withLock {
            XCTAssertEqual(2, x)
        }
    }

    func testConditionLockMutualExclusion() {
        let l = ConditionLock(value: 0)

        var x = 1
        let q = DispatchQueue(label: "q")
        let g = DispatchGroup()
        let sem1 = DispatchSemaphore(value: 0)
        let sem2 = DispatchSemaphore(value: 0)

        l.lock()

        q.async(group: g) {
            sem1.signal()
            l.lock()
            x = 2
            l.unlock()
            sem2.signal()
        }

        sem1.wait()
        XCTAssertEqual(DispatchTimeoutResult.timedOut,
                       g.wait(timeout: .now() + 0.1))
        XCTAssertEqual(1, x)

        l.unlock()
        sem2.wait()

        l.lock()
        XCTAssertEqual(2, x)
        l.unlock()
    }

    func testConditionLock() {
        let l = ConditionLock(value: 0)
        let q = DispatchQueue(label: "q")
        let sem = DispatchSemaphore(value: 0)

        XCTAssertEqual(0, l.value)

        l.lock()
        l.unlock(withValue: 1)

        XCTAssertEqual(1, l.value)

        q.async {
            l.lock(whenValue: 2)
            l.unlock(withValue: 3)
            sem.signal()
        }

        usleep(100_000)

        l.lock()
        l.unlock(withValue: 2)

        sem.wait()
        l.lock(whenValue: 3)
        l.unlock()

        XCTAssertEqual(false, l.lock(whenValue: 4, timeoutSeconds: 0.1))

        XCTAssertEqual(true, l.lock(whenValue: 3, timeoutSeconds: 0.01))
        l.unlock()

        q.async {
            usleep(100_000)

            l.lock()
            l.unlock(withValue: 4)
            sem.signal()
        }

        XCTAssertEqual(true, l.lock(whenValue: 4, timeoutSeconds: 10))
        l.unlock()
    }

    func testConditionLockWithDifferentConditions() {
        for _ in 0..<200 {
            let l = ConditionLock(value: 0)
            let q1 = DispatchQueue(label: "q1")
            let q2 = DispatchQueue(label: "q2")

            let readySem = DispatchSemaphore(value: 0)
            let doneSem = DispatchSemaphore(value: 0)

            q1.async {
                readySem.signal()

                l.lock(whenValue: 1)
                l.unlock()
                XCTAssertEqual(1, l.value)

                doneSem.signal()
            }

            q2.async {
                readySem.signal()

                l.lock(whenValue: 2)
                l.unlock()
                XCTAssertEqual(2, l.value)

                doneSem.signal()
            }

            readySem.wait()
            readySem.wait()
            l.lock()
            l.unlock(withValue: 1)

            doneSem.wait() /* job on 'q1' is done */

            XCTAssertEqual(1, l.value)
            l.lock()
            l.unlock(withValue: 2)

            doneSem.wait() /* job on 'q2' is done */
        }
    }

    func testAtomicBoxDoesNotTriviallyLeak() throws {
        class SomeClass {}
        weak var weakSomeInstance1: SomeClass? = nil
        weak var weakSomeInstance2: SomeClass? = nil
        ({
            let someInstance = SomeClass()
            weakSomeInstance1 = someInstance
            let someAtomic = AtomicBox(value: someInstance)
            let loadedFromAtomic = someAtomic.load()
            weakSomeInstance2 = loadedFromAtomic
            XCTAssertNotNil(weakSomeInstance1)
            XCTAssertNotNil(weakSomeInstance2)
            XCTAssert(someInstance === loadedFromAtomic)
        })()
        XCTAssertNil(weakSomeInstance1)
        XCTAssertNil(weakSomeInstance2)
    }

    func testAtomicBoxCompareAndExchangeWorksIfEqual() throws {
        class SomeClass {}
        weak var weakSomeInstance1: SomeClass? = nil
        weak var weakSomeInstance2: SomeClass? = nil
        weak var weakSomeInstance3: SomeClass? = nil
        ({
            let someInstance1 = SomeClass()
            let someInstance2 = SomeClass()
            weakSomeInstance1 = someInstance1

            let atomic = AtomicBox(value: someInstance1)
            var loadedFromAtomic = atomic.load()
            XCTAssert(someInstance1 === loadedFromAtomic)
            weakSomeInstance2 = loadedFromAtomic

            XCTAssertTrue(atomic.compareAndExchange(expected: loadedFromAtomic, desired: someInstance2))

            loadedFromAtomic = atomic.load()
            weakSomeInstance3 = loadedFromAtomic
            XCTAssert(someInstance1 !== loadedFromAtomic)
            XCTAssert(someInstance2 === loadedFromAtomic)

            XCTAssertNotNil(weakSomeInstance1)
            XCTAssertNotNil(weakSomeInstance2)
            XCTAssertNotNil(weakSomeInstance3)
            XCTAssert(weakSomeInstance1 === weakSomeInstance2 && weakSomeInstance2 !== weakSomeInstance3)
        })()
        XCTAssertNil(weakSomeInstance1)
        XCTAssertNil(weakSomeInstance2)
        XCTAssertNil(weakSomeInstance3)
    }

    func testAtomicBoxCompareAndExchangeWorksIfNotEqual() throws {
        class SomeClass {}
        weak var weakSomeInstance1: SomeClass? = nil
        weak var weakSomeInstance2: SomeClass? = nil
        weak var weakSomeInstance3: SomeClass? = nil
        ({
            let someInstance1 = SomeClass()
            let someInstance2 = SomeClass()
            weakSomeInstance1 = someInstance1

            let atomic = AtomicBox(value: someInstance1)
            var loadedFromAtomic = atomic.load()
            XCTAssert(someInstance1 === loadedFromAtomic)
            weakSomeInstance2 = loadedFromAtomic

            XCTAssertFalse(atomic.compareAndExchange(expected: someInstance2, desired: someInstance2))
            XCTAssertFalse(atomic.compareAndExchange(expected: SomeClass(), desired: someInstance2))
            XCTAssertTrue(atomic.load() === someInstance1)

            loadedFromAtomic = atomic.load()
            weakSomeInstance3 = someInstance2
            XCTAssert(someInstance1 === loadedFromAtomic)
            XCTAssert(someInstance2 !== loadedFromAtomic)

            XCTAssertNotNil(weakSomeInstance1)
            XCTAssertNotNil(weakSomeInstance2)
            XCTAssertNotNil(weakSomeInstance3)
        })()
        XCTAssertNil(weakSomeInstance1)
        XCTAssertNil(weakSomeInstance2)
        XCTAssertNil(weakSomeInstance3)
    }

    func testAtomicBoxStoreWorks() throws {
        class SomeClass {}
        weak var weakSomeInstance1: SomeClass? = nil
        weak var weakSomeInstance2: SomeClass? = nil
        weak var weakSomeInstance3: SomeClass? = nil
        ({
            let someInstance1 = SomeClass()
            let someInstance2 = SomeClass()
            weakSomeInstance1 = someInstance1

            let atomic = AtomicBox(value: someInstance1)
            var loadedFromAtomic = atomic.load()
            XCTAssert(someInstance1 === loadedFromAtomic)
            weakSomeInstance2 = loadedFromAtomic

            atomic.store(someInstance2)

            loadedFromAtomic = atomic.load()
            weakSomeInstance3 = loadedFromAtomic
            XCTAssert(someInstance1 !== loadedFromAtomic)
            XCTAssert(someInstance2 === loadedFromAtomic)

            XCTAssertNotNil(weakSomeInstance1)
            XCTAssertNotNil(weakSomeInstance2)
            XCTAssertNotNil(weakSomeInstance3)
        })()
        XCTAssertNil(weakSomeInstance1)
        XCTAssertNil(weakSomeInstance2)
        XCTAssertNil(weakSomeInstance3)
    }

    func testAtomicBoxCompareAndExchangeOntoItselfWorks() {
        let q = DispatchQueue(label: "q")
        let g = DispatchGroup()
        let sem1 = DispatchSemaphore(value: 0)
        let sem2 = DispatchSemaphore(value: 0)
        class SomeClass {}
        weak var weakInstance: SomeClass?
        ({
            let instance = SomeClass()
            weakInstance = instance

            let atomic = AtomicBox(value: instance)
            q.async(group: g) {
                sem1.signal()
                sem2.wait()
                for _ in 0..<1000 {
                    XCTAssertTrue(atomic.compareAndExchange(expected: instance, desired: instance))
                }
            }
            sem2.signal()
            sem1.wait()
            for _ in 0..<1000 {
                XCTAssertTrue(atomic.compareAndExchange(expected: instance, desired: instance))
            }
            g.wait()
            let v = atomic.load()
            XCTAssert(v === instance)
        })()
        XCTAssertNil(weakInstance)
    }
}
