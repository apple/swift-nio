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
@testable import NIO

public func getRandomNumbers(count: Int) -> [UInt8] {
    var values: [UInt8] = .init(repeating: 0, count: count)
    let fd = open("/dev/urandom", O_RDONLY)
    precondition(fd >= 0)
    defer {
        close(fd)
    }
    _ = values.withUnsafeMutableBytes { ptr in
        read(fd, ptr.baseAddress!, ptr.count)
    }
    return values
}

class HeapTests: XCTestCase {
    func testSimple() throws {
        var h = Heap<Int>(type: .maxHeap)
        h.append(1)
        h.append(3)
        h.append(2)
        XCTAssertEqual(3, h.removeRoot())
        XCTAssertTrue(h.checkHeapProperty())
    }

    func testSortedDesc() throws {
        var maxHeap = Heap<Int>(type: .maxHeap)
        var minHeap = Heap<Int>(type: .minHeap)

        var input = [16, 14, 10, 9, 8, 7, 4, 3, 2, 1]
        input.forEach {
            minHeap.append($0)
            maxHeap.append($0)
            XCTAssertTrue(minHeap.checkHeapProperty())
            XCTAssertTrue(maxHeap.checkHeapProperty())
        }
        var minHeapInputPtr = input.count - 1
        var maxHeapInputPtr = 0
        while let maxE = maxHeap.removeRoot(), let minE = minHeap.removeRoot() {
            XCTAssertEqual(maxE, input[maxHeapInputPtr], "\(maxHeap.debugDescription)")
            XCTAssertEqual(minE, input[minHeapInputPtr])
            maxHeapInputPtr += 1
            minHeapInputPtr -= 1
            XCTAssertTrue(minHeap.checkHeapProperty(), "\(minHeap.debugDescription)")
            XCTAssertTrue(maxHeap.checkHeapProperty())
        }
        XCTAssertEqual(-1, minHeapInputPtr)
        XCTAssertEqual(input.count, maxHeapInputPtr)
    }

    func testSortedAsc() throws {
        var maxHeap = Heap<Int>(type: .maxHeap)
        var minHeap = Heap<Int>(type: .minHeap)

        var input = Array([16, 14, 10, 9, 8, 7, 4, 3, 2, 1].reversed())
        input.forEach {
            minHeap.append($0)
            maxHeap.append($0)
        }
        var minHeapInputPtr = 0
        var maxHeapInputPtr = input.count - 1
        while let maxE = maxHeap.removeRoot(), let minE = minHeap.removeRoot() {
            XCTAssertEqual(maxE, input[maxHeapInputPtr])
            XCTAssertEqual(minE, input[minHeapInputPtr])
            maxHeapInputPtr -= 1
            minHeapInputPtr += 1
        }
        XCTAssertEqual(input.count, minHeapInputPtr)
        XCTAssertEqual(-1, maxHeapInputPtr)
    }

    func testAddAndRemoveRandomNumbers() throws {
        var maxHeap = Heap<UInt8>(type: .maxHeap)
        var minHeap = Heap<UInt8>(type: .minHeap)
        var maxHeapLast = UInt8.max
        var minHeapLast = UInt8.min

        let N = 100

        for n in getRandomNumbers(count: N) {
            maxHeap.append(n)
            minHeap.append(n)
            XCTAssertTrue(maxHeap.checkHeapProperty(), maxHeap.debugDescription)
            XCTAssertTrue(minHeap.checkHeapProperty(), maxHeap.debugDescription)

            XCTAssertEqual(Array(minHeap.sorted()), Array(minHeap))
            XCTAssertEqual(Array(maxHeap.sorted().reversed()), Array(maxHeap))
        }

        for _ in 0..<N/2 {
            var value = maxHeap.removeRoot()!
            XCTAssertLessThanOrEqual(value, maxHeapLast)
            maxHeapLast = value
            value = minHeap.removeRoot()!
            XCTAssertGreaterThanOrEqual(value, minHeapLast)
            minHeapLast = value

            XCTAssertTrue(minHeap.checkHeapProperty())
            XCTAssertTrue(maxHeap.checkHeapProperty())

            XCTAssertEqual(Array(minHeap.sorted()), Array(minHeap))
            XCTAssertEqual(Array(maxHeap.sorted().reversed()), Array(maxHeap))
        }

        maxHeapLast = UInt8.max
        minHeapLast = UInt8.min

        for n in getRandomNumbers(count: N) {
            maxHeap.append(n)
            minHeap.append(n)
            XCTAssertTrue(maxHeap.checkHeapProperty(), maxHeap.debugDescription)
            XCTAssertTrue(minHeap.checkHeapProperty(), maxHeap.debugDescription)
        }

        for _ in 0..<N/2+N {
            var value = maxHeap.removeRoot()!
            XCTAssertLessThanOrEqual(value, maxHeapLast)
            maxHeapLast = value
            value = minHeap.removeRoot()!
            XCTAssertGreaterThanOrEqual(value, minHeapLast)
            minHeapLast = value

            XCTAssertTrue(minHeap.checkHeapProperty())
            XCTAssertTrue(maxHeap.checkHeapProperty())
        }

        XCTAssertEqual(0, minHeap.underestimatedCount)
        XCTAssertEqual(0, maxHeap.underestimatedCount)
    }

    func testRemoveElement() throws {
        var h = Heap<Int>(type: .maxHeap, storage: [84, 22, 19, 21, 3, 10, 6, 5, 20])!
        _ = h.remove(value: 10)
        XCTAssertTrue(h.checkHeapProperty(), "\(h.debugDescription)")
    }
}
