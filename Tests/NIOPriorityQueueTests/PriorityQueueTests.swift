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
import XCTest
@testable import NIOPriorityQueue

class PriorityQueueTest: XCTestCase {
    func testSomeStringsAsc() throws {
        var pq = PriorityQueue<String>(ascending: true)
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
        var pq = PriorityQueue<String>(ascending: true)
        pq.push("foo")
        pq.remove("bar")
        pq.remove("foo")
        XCTAssertNil(pq.pop())
        XCTAssertNil(pq.peek())
    }

    func testRemoveFromEmpty() throws {
        var pq = PriorityQueue<Int>(ascending: true)
        pq.remove(234)
        XCTAssertTrue(pq.isEmpty)
    }

    func testSomeStringsDesc() throws {
        var pq = PriorityQueue<String>(ascending: false)
        pq.push("foo")
        pq.push("bar")
        pq.push("buz")
        pq.push("qux")

        pq.remove("buz")

        XCTAssertEqual("qux", pq.peek()!)
        XCTAssertEqual("qux", pq.pop()!)

        pq.push("qux")

        XCTAssertEqual("qux", pq.peek()!)
        XCTAssertEqual("qux", pq.pop()!)

        XCTAssertEqual("foo", pq.pop()!)
        XCTAssertEqual("bar", pq.pop()!)

        XCTAssertTrue(pq.isEmpty)
    }

    func testBuildAndRemoveFromRandomPriorityQueues() {
        for ascending in [true, false] {
            for size in 0...50 {
                var pq = PriorityQueue<UInt8>(ascending: ascending)
                let randoms = getRandomNumbers(count: size)
                randoms.forEach { pq.push($0) }

                /* remove one random member, add it back and assert we're still the same */
                randoms.forEach { random in
                    var pq2 = pq
                    pq2.remove(random)
                    XCTAssertEqual(pq.count - 1, pq2.count)
                    XCTAssertNotEqual(pq, pq2)
                    pq2.push(random)
                    XCTAssertEqual(pq, pq2)
                }

                /* remove up to `n` members and add them back at the end and check that the priority queues are still the same */
                for n in 1...5 where n <= size {
                    var pq2 = pq
                    let deleted = randoms.prefix(n).map { (random: UInt8) -> UInt8 in
                        pq2.remove(random)
                        return random
                    }
                    XCTAssertEqual(pq.count - n, pq2.count)
                    XCTAssertNotEqual(pq, pq2)
                    deleted.reversed().forEach { pq2.push($0) }
                    XCTAssertEqual(pq, pq2, "pq: \(pq), pq2: \(pq2), deleted: \(deleted)")
                }
            }
        }
    }
}
