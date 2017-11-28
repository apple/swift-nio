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
}
