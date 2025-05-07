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

import Dispatch
import NIOCore
import XCTest

@testable import NIOConcurrencyHelpers

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#else
#error("The Concurrency helpers test module was unable to identify your C library.")
#endif

class NIOConcurrencyHelpersTests: XCTestCase {
    private func sumOfIntegers(until n: UInt64) -> UInt64 {
        n * (n + 1) / 2
    }

    #if canImport(Darwin)
    let noAsyncs: UInt64 = 50
    #else
    /// `swift-corelibs-libdispatch` implementation of concurrent queues only initially spawn up to `System.coreCount` threads.
    /// Afterwards they will create one thread per second.
    /// Therefore this test takes `noAsyncs - System.coreCount` seconds to execute.
    /// For example if `noAsyncs == 50` and `System.coreCount == 8` this test takes ~42 seconds to execute.
    /// On non Darwin system we therefore limit the number of async operations to `System.coreCount`.
    let noAsyncs: UInt64 = UInt64(System.coreCount)
    #endif

    @available(*, deprecated, message: "deprecated because it tests deprecated functionality")
    func testLargeContendedAtomicSum() {

        let noCounts: UInt64 = 2_000

        let q = DispatchQueue(label: "q", attributes: .concurrent)
        let g = DispatchGroup()
        let ai = NIOConcurrencyHelpers.Atomic<UInt64>(value: 0)
        let everybodyHere = DispatchSemaphore(value: 0)
        let go = DispatchSemaphore(value: 0)
        for thread in 1...self.noAsyncs {
            q.async(group: g) {
                everybodyHere.signal()
                go.wait()
                for _ in 0..<noCounts {
                    ai.add(thread)
                }
            }
        }
        for _ in 0..<self.noAsyncs {
            everybodyHere.wait()
        }
        for _ in 0..<self.noAsyncs {
            go.signal()
        }
        g.wait()
        XCTAssertEqual(sumOfIntegers(until: self.noAsyncs) * noCounts, ai.load())
    }

    @available(*, deprecated, message: "deprecated because it tests deprecated functionality")
    func testCompareAndExchangeBool() {
        let ab = Atomic<Bool>(value: true)

        XCTAssertFalse(ab.compareAndExchange(expected: false, desired: false))
        XCTAssertTrue(ab.compareAndExchange(expected: true, desired: true))

        XCTAssertFalse(ab.compareAndExchange(expected: false, desired: false))
        XCTAssertTrue(ab.compareAndExchange(expected: true, desired: false))

        XCTAssertTrue(ab.compareAndExchange(expected: false, desired: false))
        XCTAssertTrue(ab.compareAndExchange(expected: false, desired: true))
    }

    @available(*, deprecated, message: "deprecated because it tests deprecated functionality")
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

    @available(*, deprecated, message: "deprecated because it tests deprecated functionality")
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
                XCTAssertTrue(ab.compareAndExchange(expected: counter, desired: counter - 1))
                counter = counter - 1
            }
        }

        testFor(UInt8.self)
        testFor(UInt16.self)
        testFor(UInt32.self)
        testFor(UInt64.self)
        testFor(UInt.self)
    }

    @available(*, deprecated, message: "deprecated because it tests deprecated functionality")
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
                XCTAssertTrue(ab.compareAndExchange(expected: counter, desired: counter - 1))
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

    @available(*, deprecated, message: "deprecated because it tests deprecated functionality")
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

    @available(*, deprecated, message: "deprecated because it tests deprecated functionality")
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

    @available(*, deprecated, message: "deprecated because it tests deprecated functionality")
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

    @available(*, deprecated, message: "deprecated because it tests deprecated functionality")
    func testLargeContendedNIOAtomicSum() {
        let noCounts: UInt64 = 2_000

        let q = DispatchQueue(label: "q", attributes: .concurrent)
        let g = DispatchGroup()
        let ai = NIOConcurrencyHelpers.NIOAtomic<UInt64>.makeAtomic(value: 0)
        let everybodyHere = DispatchSemaphore(value: 0)
        let go = DispatchSemaphore(value: 0)
        for thread in 1...self.noAsyncs {
            q.async(group: g) {
                everybodyHere.signal()
                go.wait()
                for _ in 0..<noCounts {
                    ai.add(thread)
                }
            }
        }
        for _ in 0..<self.noAsyncs {
            everybodyHere.wait()
        }
        for _ in 0..<self.noAsyncs {
            go.signal()
        }
        g.wait()
        XCTAssertEqual(sumOfIntegers(until: self.noAsyncs) * noCounts, ai.load())
    }

    @available(*, deprecated, message: "deprecated because it tests deprecated functionality")
    func testCompareAndExchangeBoolNIOAtomic() {
        let ab = NIOAtomic<Bool>.makeAtomic(value: true)

        XCTAssertFalse(ab.compareAndExchange(expected: false, desired: false))
        XCTAssertTrue(ab.compareAndExchange(expected: true, desired: true))

        XCTAssertFalse(ab.compareAndExchange(expected: false, desired: false))
        XCTAssertTrue(ab.compareAndExchange(expected: true, desired: false))

        XCTAssertTrue(ab.compareAndExchange(expected: false, desired: false))
        XCTAssertTrue(ab.compareAndExchange(expected: false, desired: true))
    }

    @available(*, deprecated, message: "deprecated because it tests deprecated functionality")
    func testAllOperationsBoolNIOAtomic() {
        let ab = NIOAtomic<Bool>.makeAtomic(value: false)
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

    @available(*, deprecated, message: "deprecated because it tests deprecated functionality")
    func testCompareAndExchangeUIntsNIOAtomic() {
        func testFor<T: NIOAtomicPrimitive & FixedWidthInteger & UnsignedInteger>(_ value: T.Type) {
            let zero: T = 0
            let max = ~zero

            let ab = NIOAtomic<T>.makeAtomic(value: max)

            XCTAssertFalse(ab.compareAndExchange(expected: zero, desired: zero))
            XCTAssertTrue(ab.compareAndExchange(expected: max, desired: max))

            XCTAssertFalse(ab.compareAndExchange(expected: zero, desired: zero))
            XCTAssertTrue(ab.compareAndExchange(expected: max, desired: zero))

            XCTAssertTrue(ab.compareAndExchange(expected: zero, desired: zero))
            XCTAssertTrue(ab.compareAndExchange(expected: zero, desired: max))

            var counter = max
            for _ in 0..<255 {
                XCTAssertTrue(ab.compareAndExchange(expected: counter, desired: counter - 1))
                counter = counter - 1
            }
        }

        testFor(UInt8.self)
        testFor(UInt16.self)
        testFor(UInt32.self)
        testFor(UInt64.self)
        testFor(UInt.self)
    }

    @available(*, deprecated, message: "deprecated because it tests deprecated functionality")
    func testCompareAndExchangeIntsNIOAtomic() {
        func testFor<T: NIOAtomicPrimitive & FixedWidthInteger & SignedInteger>(_ value: T.Type) {
            let zero: T = 0
            let upperBound: T = 127

            let ab = NIOAtomic<T>.makeAtomic(value: upperBound)

            XCTAssertFalse(ab.compareAndExchange(expected: zero, desired: zero))
            XCTAssertTrue(ab.compareAndExchange(expected: upperBound, desired: upperBound))

            XCTAssertFalse(ab.compareAndExchange(expected: zero, desired: zero))
            XCTAssertTrue(ab.compareAndExchange(expected: upperBound, desired: zero))

            XCTAssertTrue(ab.compareAndExchange(expected: zero, desired: zero))
            XCTAssertTrue(ab.compareAndExchange(expected: zero, desired: upperBound))

            var counter = upperBound
            for _ in 0..<255 {
                XCTAssertTrue(ab.compareAndExchange(expected: counter, desired: counter - 1))
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

    @available(*, deprecated, message: "deprecated because it tests deprecated functionality")
    func testAddSubNIOAtomic() {
        func testFor<T: NIOAtomicPrimitive & FixedWidthInteger>(_ value: T.Type) {
            let zero: T = 0

            let ab = NIOAtomic<T>.makeAtomic(value: zero)

            XCTAssertEqual(0, ab.add(1))
            XCTAssertEqual(1, ab.add(41))
            XCTAssertEqual(42, ab.add(23))

            XCTAssertEqual(65, ab.load())

            XCTAssertEqual(65, ab.sub(23))
            XCTAssertEqual(42, ab.sub(41))
            XCTAssertEqual(1, ab.sub(1))

            XCTAssertEqual(0, ab.load())

            let atomic = NIOAtomic<T>.makeAtomic(value: zero)
            atomic.store(100)
            atomic.add(1)
            XCTAssertEqual(101, atomic.load())
            atomic.sub(1)
            XCTAssertEqual(100, atomic.load())
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

    @available(*, deprecated, message: "deprecated because it tests deprecated functionality")
    func testExchangeNIOAtomic() {
        func testFor<T: NIOAtomicPrimitive & FixedWidthInteger>(_ value: T.Type) {
            let zero: T = 0

            let ab = NIOAtomic<T>.makeAtomic(value: zero)

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

    @available(*, deprecated, message: "deprecated because it tests deprecated functionality")
    func testLoadStoreNIOAtomic() {
        func testFor<T: NIOAtomicPrimitive & FixedWidthInteger>(_ value: T.Type) {
            let zero: T = 0

            let ab = NIOAtomic<T>.makeAtomic(value: zero)

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
        let l = NIOLock()

        nonisolated(unsafe) var x = 1
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
        XCTAssertEqual(
            DispatchTimeoutResult.timedOut,
            g.wait(timeout: .now() + 0.1)
        )
        XCTAssertEqual(1, x)

        l.unlock()
        sem2.wait()

        l.lock()
        XCTAssertEqual(2, x)
        l.unlock()
    }

    func testWithLockMutualExclusion() {
        let l = NIOLock()

        nonisolated(unsafe) var x = 1
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
            XCTAssertEqual(
                DispatchTimeoutResult.timedOut,
                g.wait(timeout: .now() + 0.1)
            )
            XCTAssertEqual(1, x)
        }
        sem2.wait()

        l.withLock {
            XCTAssertEqual(2, x)
        }
    }

    func testConditionLockMutualExclusion() {
        let l = ConditionLock(value: 0)

        nonisolated(unsafe) var x = 1
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
        XCTAssertEqual(
            DispatchTimeoutResult.timedOut,
            g.wait(timeout: .now() + 0.1)
        )
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

            doneSem.wait()  // job on 'q1' is done

            XCTAssertEqual(1, l.value)
            l.lock()
            l.unlock(withValue: 2)

            doneSem.wait()  // job on 'q2' is done
        }
    }

    @available(*, deprecated, message: "AtomicBox is deprecated, this is a test for the deprecated functionality")
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

    @available(*, deprecated, message: "AtomicBox is deprecated, this is a test for the deprecated functionality")
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

    @available(*, deprecated, message: "AtomicBox is deprecated, this is a test for the deprecated functionality")
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

    @available(*, deprecated, message: "AtomicBox is deprecated, this is a test for the deprecated functionality")
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

    @available(*, deprecated, message: "AtomicBox is deprecated, this is a test for the deprecated functionality")
    func testAtomicBoxCompareAndExchangeOntoItselfWorks() {
        let q = DispatchQueue(label: "q")
        let g = DispatchGroup()
        let sem1 = DispatchSemaphore(value: 0)
        let sem2 = DispatchSemaphore(value: 0)
        final class SomeClass: Sendable {}
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

    @available(*, deprecated, message: "AtomicBox is deprecated, this is a test for the deprecated functionality")
    func testAtomicLoadMassLoadAndStore() {
        let writer = DispatchQueue(label: "\(#file):writer")
        let reader = DispatchQueue(label: "\(#file):reader")
        let g = DispatchGroup()
        let writerArrived = DispatchSemaphore(value: 0)
        let readerArrived = DispatchSemaphore(value: 0)
        let go = DispatchSemaphore(value: 0)
        let iterations = 100_000

        final class Foo: Sendable {
            let x: Int

            init(_ x: Int) {
                self.x = x
            }
        }

        let box: AtomicBox<Foo> = .init(value: Foo(iterations))

        writer.async(group: g) {
            writerArrived.signal()
            go.wait()

            for i in 0..<iterations {
                box.store(Foo(i))
            }
        }

        reader.async(group: g) {
            readerArrived.signal()
            go.wait()

            for _ in 0..<iterations {
                if box.load().x < 0 {
                    XCTFail("bad")
                }
            }
        }

        writerArrived.wait()
        readerArrived.wait()
        go.signal()
        go.signal()

        g.wait()
    }

    @available(*, deprecated, message: "AtomicBox is deprecated, this is a test for the deprecated functionality")
    func testAtomicBoxCompareAndExchangeOntoItself() {
        class Foo {}
        weak var weakF: Foo? = nil
        weak var weakG: Foo? = nil

        @inline(never)
        func doIt() {
            let f = Foo()
            let g = Foo()
            weakF = f
            weakG = g
            let box = AtomicBox<Foo>(value: f)
            XCTAssertFalse(box.compareAndExchange(expected: g, desired: g))
            XCTAssertTrue(box.compareAndExchange(expected: f, desired: f))
            XCTAssertFalse(box.compareAndExchange(expected: g, desired: g))
            XCTAssertTrue(box.compareAndExchange(expected: f, desired: g))
        }
        doIt()
        assert(weakF == nil, within: .seconds(1))
        assert(weakG == nil, within: .seconds(1))
    }

    @available(*, deprecated, message: "AtomicBox is deprecated, this is a test for the deprecated functionality")
    func testLoadAndExchangeHammering() {
        let allDeallocations = NIOAtomic<Int>.makeAtomic(value: 0)
        let iterations = 10_000

        @inline(never)
        func doIt() {
            let box = AtomicBox(value: IntHolderWithDeallocationTracking(0, allDeallocations: allDeallocations))

            spawnAndJoinRacingThreads(count: 6) { i in
                switch i {
                case 0:  // writer
                    for i in 1...iterations {
                        let nextObject = box.exchange(with: .init(i, allDeallocations: allDeallocations))
                        XCTAssertEqual(nextObject.value, i - 1)
                    }
                default:  // readers
                    while true {
                        if box.load().value < 0 || box.load().value > iterations {
                            XCTFail("bad")
                        }
                        if box.load().value == iterations {
                            break
                        }
                    }
                }
            }
        }

        doIt()
        assert(allDeallocations.load() == iterations + 1, within: .seconds(1))
    }

    @available(*, deprecated, message: "AtomicBox is deprecated, this is a test for the deprecated functionality")
    func testLoadAndStoreHammering() {
        let allDeallocations = NIOAtomic<Int>.makeAtomic(value: 0)
        let iterations = 10_000

        @inline(never)
        func doIt() {
            let box = AtomicBox(value: IntHolderWithDeallocationTracking(0, allDeallocations: allDeallocations))

            spawnAndJoinRacingThreads(count: 6) { i in
                switch i {
                case 0:  // writer
                    for i in 1...iterations {
                        box.store(IntHolderWithDeallocationTracking(i, allDeallocations: allDeallocations))
                    }
                default:  // readers
                    while true {
                        if box.load().value < 0 || box.load().value > iterations {
                            XCTFail("loaded the wrong value")
                        }
                        if box.load().value == iterations {
                            break
                        }
                    }
                }
            }
        }

        doIt()
        assert(allDeallocations.load() == iterations + 1, within: .seconds(1))
    }

    @available(*, deprecated, message: "AtomicBox is deprecated, this is a test for the deprecated functionality")
    func testLoadAndCASHammering() {
        let allDeallocations = NIOAtomic<Int>.makeAtomic(value: 0)
        let iterations = 1_000

        @inline(never)
        func doIt() {
            let box = AtomicBox(value: IntHolderWithDeallocationTracking(0, allDeallocations: allDeallocations))

            spawnAndJoinRacingThreads(count: 6) { i in
                switch i {
                case 0:  // writer
                    for i in 1...iterations {
                        let old = box.load()
                        XCTAssertEqual(i - 1, old.value)
                        if !box.compareAndExchange(
                            expected: old,
                            desired: .init(i, allDeallocations: allDeallocations)
                        ) {
                            XCTFail("compare and exchange didn't work but it should have")
                        }
                    }
                default:  // readers
                    while true {
                        if box.load().value < 0 || box.load().value > iterations {
                            XCTFail("loaded wrong value")
                        }
                        if box.load().value == iterations {
                            break
                        }
                    }
                }
            }
        }

        doIt()
        assert(allDeallocations.load() == iterations + 1, within: .seconds(1))
    }

    @available(*, deprecated, message: "AtomicBox is deprecated, this is a test for the deprecated functionality")
    func testMultipleLoadsRacingWhilstStoresAreGoingOn() {
        // regression test for https://github.com/apple/swift-nio/pull/1287#discussion_r353932225
        let allDeallocations = NIOAtomic<Int>.makeAtomic(value: 0)
        let iterations = 10_000

        @inline(never)
        func doIt() {
            let box = AtomicBox(value: IntHolderWithDeallocationTracking(0, allDeallocations: allDeallocations))
            spawnAndJoinRacingThreads(count: 3) { i in
                switch i {
                case 0:
                    var last = Int.min
                    while last < iterations {
                        let loaded = box.load()
                        XCTAssertGreaterThanOrEqual(loaded.value, last)
                        last = loaded.value
                    }
                case 1:
                    for n in 1...iterations {
                        box.store(.init(n, allDeallocations: allDeallocations))
                    }
                case 2:
                    var last = Int.min
                    while last < iterations {
                        let loaded = box.load()
                        XCTAssertGreaterThanOrEqual(loaded.value, last)
                        last = loaded.value
                    }
                default:
                    preconditionFailure("thread \(i)?!")
                }
            }
        }

        doIt()
        XCTAssertEqual(iterations + 1, allDeallocations.load())
    }

    func testNIOLockedValueBox() {
        struct State {
            var count: Int = 0
        }

        let lv = NIOLockedValueBox<State>(State())
        spawnAndJoinRacingThreads(count: 50) { _ in
            for _ in 0..<1000 {
                lv.withLockedValue { state in
                    state.count += 1
                }
            }
        }

        XCTAssertEqual(50_000, lv.withLockedValue { $0.count })
    }

    func testNIOLockedValueBoxHandlesThingsWithTransitiveClassesProperly() {
        struct State {
            var counts: [Int] = []
        }

        let lv = NIOLockedValueBox<State>(State())
        spawnAndJoinRacingThreads(count: 50) { _ in
            for i in 0..<1000 {
                lv.withLockedValue { state in
                    state.counts.append(i)
                }
            }
        }

        XCTAssertEqual(50_000, lv.withLockedValue { $0.counts.count })
    }
}

func spawnAndJoinRacingThreads(count: Int, _ body: @Sendable @escaping (Int) -> Void) {
    let go = DispatchSemaphore(value: 0)  // will be incremented when the threads are supposed to run (and race).
    let arrived = Array(repeating: DispatchSemaphore(value: 0), count: count)  // waiting for all threads to arrive

    let group = DispatchGroup()
    for i in 0..<count {
        DispatchQueue(label: "\(#file):\(#line):\(i)").async(group: group) {
            arrived[i].signal()
            go.wait()
            body(i)
        }
    }

    for sem in arrived {
        sem.wait()
    }
    // all the threads are ready to go
    for _ in 0..<count {
        go.signal()
    }

    group.wait()
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

@available(*, deprecated, message: "deprecated because it is used to test deprecated functionality")
private final class IntHolderWithDeallocationTracking: Sendable {
    let value: Int
    let allDeallocations: NIOAtomic<Int>

    init(_ x: Int, allDeallocations: NIOAtomic<Int>) {
        self.value = x
        self.allDeallocations = allDeallocations
    }

    deinit {
        self.allDeallocations.add(1)
    }
}
