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

class CircularBufferTests: XCTestCase {
    func testTrivial() {
        var ring = CircularBuffer<Int>(initialRingCapacity: 8)
        ring.append(1)
        XCTAssertEqual(1, ring.removeFirst())
    }

    func testAddRemoveInALoop() {
        var ring = CircularBuffer<Int>(initialRingCapacity: 8)
        XCTAssertTrue(ring.isEmpty)
        XCTAssertEqual(0, ring.count)

        for f in 0..<1000 {
            ring.append(f)
            XCTAssertEqual(f, ring.removeFirst())
            XCTAssertTrue(ring.isEmpty)
            XCTAssertEqual(0, ring.count)
        }
    }

    func testAddAllRemoveAll() {
        var ring = CircularBuffer<Int>(initialRingCapacity: 8)
        XCTAssertTrue(ring.isEmpty)
        XCTAssertEqual(0, ring.count)

        for f in 1..<1000 {
            ring.append(f)
            XCTAssertEqual(f, ring.count)
        }
        for f in 1..<1000 {
            XCTAssertEqual(f, ring.removeFirst())
            XCTAssertEqual(999 - f, ring.count)
        }
        XCTAssertTrue(ring.isEmpty)
    }

    func testRemoveAt() {
        var ring = CircularBuffer<Int>(initialRingCapacity: 4)
        for idx in 0..<7 {
            ring.prepend(idx)
        }

        XCTAssertEqual(7, ring.count)
        _ = ring.remove(at: 1)
        XCTAssertEqual(6, ring.count)
        XCTAssertEqual(0, ring.last)

        let last = ring.remove(at: ring.endIndex - 1)
        XCTAssertEqual(0, last)
        XCTAssertEqual(1, ring.last)

        let first = ring.remove(at: 0)
        XCTAssertEqual(6, first)
        XCTAssertEqual(4, ring.first)
    }

    func testHarderExpansion() {
        var ring = CircularBuffer<Int>(initialRingCapacity: 3)
        XCTAssertEqual(ring.indices, 0..<0)

        ring.append(1)
        XCTAssertEqual(ring.count, 1)
        XCTAssertEqual(ring[0], 1)
        XCTAssertEqual(ring.indices, 0..<1)

        ring.append(2)
        XCTAssertEqual(ring.count, 2)
        XCTAssertEqual(ring[0], 1)
        XCTAssertEqual(ring[1], 2)
        XCTAssertEqual(ring.indices, 0..<2)

        ring.append(3)
        XCTAssertEqual(ring.count, 3)
        XCTAssertEqual(ring[0], 1)
        XCTAssertEqual(ring[1], 2)
        XCTAssertEqual(ring[2], 3)
        XCTAssertEqual(ring.indices, 0..<3)


        XCTAssertEqual(1, ring.removeFirst())
        XCTAssertEqual(ring.count, 2)
        XCTAssertEqual(ring[0], 2)
        XCTAssertEqual(ring[1], 3)
        XCTAssertEqual(ring.indices, 0..<2)

        XCTAssertEqual(2, ring.removeFirst())
        XCTAssertEqual(ring.count, 1)
        XCTAssertEqual(ring[0], 3)
        XCTAssertEqual(ring.indices, 0..<1)

        ring.append(5)
        XCTAssertEqual(ring.count, 2)
        XCTAssertEqual(ring[0], 3)
        XCTAssertEqual(ring[1], 5)
        XCTAssertEqual(ring.indices, 0..<2)

        ring.append(6)
        XCTAssertEqual(ring.count, 3)
        XCTAssertEqual(ring[0], 3)
        XCTAssertEqual(ring[1], 5)
        XCTAssertEqual(ring[2], 6)
        XCTAssertEqual(ring.indices, 0..<3)

        ring.append(7)
        XCTAssertEqual(ring.count, 4)
        XCTAssertEqual(ring[0], 3)
        XCTAssertEqual(ring[1], 5)
        XCTAssertEqual(ring[2], 6)
        XCTAssertEqual(ring[3], 7)
        XCTAssertEqual(ring.indices, 0..<4)
    }

    func testCollection() {
        var ring = CircularBuffer<Int>(initialRingCapacity: 4)
        XCTAssertEqual(ring.indices, 0..<0)
        XCTAssertEqual(ring.startIndex, 0)
        XCTAssertEqual(ring.endIndex, 0)

        for idx in 0..<5 {
            ring.append(idx)
        }

        XCTAssertFalse(ring.isEmpty)
        XCTAssertEqual(5, ring.count)

        XCTAssertEqual(ring.indices, 0..<5)
        XCTAssertEqual(ring.startIndex, 0)
        XCTAssertEqual(ring.endIndex, 5)

        XCTAssertEqual(ring.index(after: 1), 2)
        XCTAssertEqual(ring.index(before: 3), 2)
        
        let actualValues = [Int](ring)
        let expectedValues = [0, 1, 2, 3, 4]
        XCTAssertEqual(expectedValues, actualValues)
    }

    func testReplacingSubrangeOfElements() {
        var ring = CircularBuffer<Int>(initialRingCapacity: 4)
        for idx in 0..<50 {
            ring.prepend(idx)
        }
        XCTAssertEqual(50, ring.count)
        ring.replaceSubrange(20..<25, with: [99])

        XCTAssertEqual(ring.count, 46)
        XCTAssertEqual(ring[19], 30)
        XCTAssertEqual(ring[20], 99)
        XCTAssertEqual(ring[21], 24)
        ring.replaceSubrange(ring.startIndex..<ring.endIndex, with: [])
        XCTAssertTrue(ring.isEmpty)

        ring.prepend(1)
        ring.prepend(2)
        XCTAssertEqual(2, ring.count)
        XCTAssertEqual(2, ring.first)
        XCTAssertEqual(1, ring.last)
        ring.replaceSubrange(ring.startIndex..<ring.endIndex, with: [3,4])
        XCTAssertEqual(2, ring.count)
        XCTAssertEqual(3, ring.first)
        XCTAssertEqual(4, ring.last)

        ring.replaceSubrange(ring.startIndex..<ring.endIndex, with: [0,1,2,3,4,5,6,7,8,9])
        XCTAssertEqual(10, ring.count)
        XCTAssertEqual(0, ring.first)
        XCTAssertEqual(9, ring.last)

        ring.replaceSubrange(0..<0, with: [])
        XCTAssertEqual(10, ring.count)
    }

    func testWeCanDistinguishBetweenEmptyAndFull() {
        var ring = CircularBuffer<Int>(initialRingCapacity: 4)
        XCTAssertTrue(ring.isEmpty)
        for idx in 0..<4 {
            ring.append(idx)
        }
        XCTAssertEqual(4, ring.count)
        XCTAssertFalse(ring.isEmpty)
    }

    func testExpandZeroBasedRingWorks() {
        var ring = CircularBuffer<Int>(initialRingCapacity: 4)
        for idx in 0..<5 {
            ring.append(idx)
        }
        for idx in 0..<5 {
            XCTAssertEqual(idx, ring[idx])
        }
    }

    func testExpandNonZeroBasedRingWorks() {
        var ring = CircularBuffer<Int>(initialRingCapacity: 4)
        for idx in 0..<4 {
            ring.append(idx)
        }
        /* the underlying buffer should now be filled from 0 to max */
        for idx in 0..<4 {
            XCTAssertEqual(idx, ring[idx])
        }
        XCTAssertEqual(0, ring.removeFirst())
        /* now the first element is gone, ie. the ring starts at index 1 now */
        for idx in 0..<3 {
            XCTAssertEqual(idx + 1, ring[idx])
        }
        ring.append(4)
        XCTAssertEqual(1, ring.first!)
        /* now the last element should be at ring position 0 */
        for idx in 0..<4 {
            XCTAssertEqual(idx + 1, ring[idx])
        }
        /* and now we'll make it expand */
        ring.append(5)
        for idx in 0..<5 {
            XCTAssertEqual(idx + 1, ring[idx])
        }
    }

    func testEmptyingExpandedRingWorks() {
        var ring = CircularBuffer<Int>(initialRingCapacity: 2)
        for idx in 0..<4 {
            ring.append(idx)
        }
        for idx in 0..<4 {
            XCTAssertEqual(idx, ring[idx])
        }
        for idx in 0..<4 {
            XCTAssertEqual(idx, ring.removeFirst())
        }
        XCTAssertTrue(ring.isEmpty)
        XCTAssertNil(ring.first)
    }

    func testChangeElements() {
        var ring = CircularBuffer<Int>(initialRingCapacity: 100)
        for idx in 0..<50 {
            ring.append(idx)
        }
        var changes: [(Int, Int)] = []
        for (idx, element) in ring.enumerated() {
            XCTAssertEqual(idx, element)
            changes.append((idx, element * 2))
        }
        for change in changes {
            ring[change.0] = change.1
        }
        for (idx, element) in ring.enumerated() {
            XCTAssertEqual(idx * 2, element)
        }
    }

    func testSliceTheRing() {
        var ring = CircularBuffer<Int>(initialRingCapacity: 100)
        for idx in 0..<50 {
            ring.append(idx)
        }

        let slice = ring[Range(25..<30)]
        for (idx, element) in slice.enumerated() {
            XCTAssertEqual(idx + 25, element)
        }
    }

    func testCount() {
        var ring = CircularBuffer<Int>(initialRingCapacity: 4)
        ring.append(1)
        XCTAssertEqual(1, ring.count)
        ring.append(2)
        XCTAssertEqual(2, ring.count)
        XCTAssertEqual(1, ring.removeFirst())
        ring.append(3)
        XCTAssertEqual(2, ring.count)
        XCTAssertEqual(2, ring.removeFirst())
        ring.append(4)

        XCTAssertEqual(2, ring.count)
        XCTAssertEqual(3, ring.removeFirst())
        ring.append(5)

        XCTAssertEqual(3, ring.headIdx)
        XCTAssertEqual(1, ring.tailIdx)
        XCTAssertEqual(2, ring.count)
        XCTAssertEqual(4, ring.removeFirst())
        XCTAssertEqual(5, ring.removeFirst())
        XCTAssertEqual(0, ring.count)
        XCTAssertTrue(ring.isEmpty)
    }

    func testFirst() {
        var ring = CircularBuffer<Int>(initialRingCapacity: 3)
        XCTAssertNil(ring.first)
        ring.append(1)
        XCTAssertEqual(1, ring.first)
        XCTAssertEqual(1, ring.removeFirst())
        XCTAssertNil(ring.first)
    }

    func testLast() {
        var ring = CircularBuffer<Int>(initialRingCapacity: 3)
        XCTAssertNil(ring.last)
        ring.prepend(1)
        XCTAssertEqual(1, ring.last)
        XCTAssertEqual(1, ring.removeLast())
        XCTAssertNil(ring.last)
        XCTAssertEqual(0, ring.count)
        XCTAssertTrue(ring.isEmpty)
        ring.prepend(9)
        ring.prepend(5)
        XCTAssertEqual(9, ring.last)
        XCTAssertEqual(ring.dropLast().last, ring.dropLast().first)
        XCTAssertEqual(5, ring.dropLast().first)
        XCTAssertFalse(ring.isEmpty)
        XCTAssertEqual(2, ring.count)
        XCTAssertTrue(ring.dropLast(2).isEmpty)
        ring.prepend(1)
        ring.prepend(2)
        XCTAssertEqual(4, ring.count)
        ring.removeLast(3)
        XCTAssertEqual(1, ring.count)
        XCTAssertEqual(2, ring.last)

        ring = CircularBuffer<Int>(initialRingCapacity: 4)
        ring.append(9)
        ring.prepend(0)
        ring.prepend(1)
        XCTAssertEqual(3, ring.count)
        ring.removeLast(3)
        XCTAssertTrue(ring.isEmpty)
    }

    func testOperateOnBothSides() {
        var ring = CircularBuffer<Int>(initialRingCapacity: 3)
        XCTAssertNil(ring.last)
        ring.prepend(1)
        ring.prepend(2)

        XCTAssertEqual(1, ring.last)
        XCTAssertEqual(2, ring.first)

        XCTAssertEqual(1, ring.removeLast())
        XCTAssertEqual(2, ring.removeFirst())

        XCTAssertNil(ring.last)
        XCTAssertNil(ring.first)
        XCTAssertEqual(0, ring.count)
        XCTAssertTrue(ring.isEmpty)
    }


    func testPrependExpandBuffer() {
        var ring = CircularBuffer<Int>(initialRingCapacity: 3)
        for f in 1..<1000 {
            ring.prepend(f)
            XCTAssertEqual(f, ring.count)
        }
        for f in 1..<1000 {
            XCTAssertEqual(f, ring.removeLast())
        }
        XCTAssertTrue(ring.isEmpty)
        XCTAssertEqual(0, ring.count)
    }

    func testRemoveAllKeepingCapacity() {
        var ring = CircularBuffer<Int>(initialRingCapacity: 2)
        XCTAssertEqual(ring.capacity, 2)
        ring.append(1)
        ring.append(2)
        // we're full so it will have doubled
        XCTAssertEqual(ring.capacity, 4)
        XCTAssertEqual(ring.count, 2)
        ring.removeAll(keepingCapacity: true)
        XCTAssertEqual(ring.capacity, 4)
        XCTAssertEqual(ring.count, 0)
    }

    func testRemoveAllNotKeepingCapacity() {
        var ring = CircularBuffer<Int>(initialRingCapacity: 2)
        XCTAssertGreaterThanOrEqual(ring.capacity, 2)
        ring.append(1)
        ring.append(2)
        // we're full so it will have doubled
        XCTAssertEqual(ring.capacity, 4)
        XCTAssertEqual(ring.count, 2)
        ring.removeAll(keepingCapacity: false)
        // 1 is the smallest capacity we have
        XCTAssertEqual(ring.capacity, 1)
        XCTAssertEqual(ring.count, 0)
        ring.append(1)
        XCTAssertEqual(ring.capacity, 2)
        XCTAssertEqual(ring.count, 1)
        ring.append(2)
        XCTAssertEqual(ring.capacity, 4)
        XCTAssertEqual(ring.count, 2)
        ring.removeAll() // default should not keep capacity
        XCTAssertEqual(ring.capacity, 1)
        XCTAssertEqual(ring.count, 0)
    }
}
