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
import XCTest
import _NIODataStructures

class PriorityQueueTest: XCTestCase {
    func testSomeStringsAsc() throws {
        var pq = PriorityQueue<String>()
        pq.push("foo")
        pq.push("bar")
        pq.push("buz")
        pq.push("qux")

        pq.remove("buz")

        XCTAssertEqual("bar", pq.peek()!)
        XCTAssertEqual("bar", pq.pop()!)

        pq.push("bar")

        XCTAssertEqual("bar", pq.peek()!)
        XCTAssertEqual("bar", pq.pop()!)

        XCTAssertEqual("foo", pq.pop()!)
        XCTAssertEqual("qux", pq.pop()!)

        XCTAssertTrue(pq.isEmpty)
    }

    func testRemoveNonExisting() throws {
        var pq = PriorityQueue<String>()
        pq.push("foo")
        pq.remove("bar")
        pq.remove("foo")
        XCTAssertNil(pq.pop())
        XCTAssertNil(pq.peek())
    }

    func testRemoveFromEmpty() throws {
        var pq = PriorityQueue<Int>()
        pq.remove(234)
        XCTAssertTrue(pq.isEmpty)
    }

    func testBuildAndRemoveFromRandomPriorityQueues() {
        for size in 0...33 {
            var pq = PriorityQueue<UInt8>()
            let randoms = getRandomNumbers(count: size)
            for number in randoms {
                pq.push(number)
            }

            // remove one random member, add it back and assert we're still the same
            for random in randoms {
                var pq2 = pq
                pq2.remove(random)
                XCTAssertEqual(pq.count - 1, pq2.count)
                XCTAssertNotEqual(pq, pq2)
                pq2.push(random)
                XCTAssertEqual(pq, pq2)
            }

            // remove up to `n` members and add them back at the end and check that the priority queues are still the same
            for n in 1...5 where n <= size {
                var pq2 = pq
                let deleted = randoms.prefix(n).map { (random: UInt8) -> UInt8 in
                    pq2.remove(random)
                    return random
                }
                XCTAssertEqual(pq.count - n, pq2.count)
                XCTAssertNotEqual(pq, pq2)
                for number in deleted.reversed() {
                    pq2.push(number)
                }
                XCTAssertEqual(pq, pq2, "pq: \(pq), pq2: \(pq2), deleted: \(deleted)")
            }
        }
    }

    func testPartialOrder() {
        let clearlyTheSmallest = SomePartiallyOrderedDataType(width: 0, height: 0)
        let clearlyTheLargest = SomePartiallyOrderedDataType(width: 100, height: 100)
        let inTheMiddles = zip(1...99, (1...99).reversed()).map { SomePartiallyOrderedDataType(width: $0, height: $1) }

        // the four values are only partially ordered (from small (top) to large (bottom)):

        //                   clearlyTheSmallest
        //                  /         |        \
        //           inTheMiddle[0]   |    inTheMiddle[1...]
        //                  \         |        /
        //                    clearlyTheLargest

        var pq = PriorityQueue<SomePartiallyOrderedDataType>()
        pq.push(clearlyTheLargest)
        pq.push(inTheMiddles[0])
        pq.push(clearlyTheSmallest)
        for number in inTheMiddles[1...] {
            pq.push(number)
        }
        let pop1 = pq.pop()
        XCTAssertEqual(clearlyTheSmallest, pop1)
        for _ in inTheMiddles {
            let popN = pq.pop()!
            XCTAssert(inTheMiddles.contains(popN))
        }
        XCTAssertEqual(clearlyTheLargest, pq.pop()!)
        XCTAssert(pq.isEmpty)
    }

    func testDescription() {
        let pq1 = PriorityQueue<Int>()
        var pq2 = PriorityQueue<Int>()
        pq2.push(1)
        pq2.push(2)
        pq2.push(3)
        XCTAssertEqual(pq1.description, "PriorityQueue(count: 0): \(Array(pq1))")
        XCTAssertEqual(pq2.description, "PriorityQueue(count: 3): \(Array(pq2))")
    }
}

/// This data type is only partially ordered. Ie. from `a < b` and `a != b` we can't imply `a > b`.
struct SomePartiallyOrderedDataType: Comparable, CustomStringConvertible {
    public static func < (lhs: SomePartiallyOrderedDataType, rhs: SomePartiallyOrderedDataType) -> Bool {
        lhs.width < rhs.width && lhs.height < rhs.height
    }

    public static func == (lhs: SomePartiallyOrderedDataType, rhs: SomePartiallyOrderedDataType) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height
    }

    private let width: Int
    private let height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var description: String {
        "(w: \(self.width), h: \(self.height))"
    }
}
