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
        var ring = CircularBuffer<Int>(initialCapacity: 8)
        ring.append(1)
        XCTAssertEqual(1, ring.removeFirst())
    }

    func testAddRemoveInALoop() {
        var ring = CircularBuffer<Int>(initialCapacity: 8)
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
        var ring = CircularBuffer<Int>(initialCapacity: 8)
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
        var ring = CircularBuffer<Int>(initialCapacity: 4)
        for idx in 0..<7 {
            ring.prepend(idx)
        }

        XCTAssertEqual(7, ring.count)
        _ = ring.remove(at: ring.startIndex.advanced(by: 1))
        XCTAssertEqual(6, ring.count)
        XCTAssertEqual(0, ring.last)
    }

    func testRemoveAtLastPosition() {
        var ring = CircularBuffer<Int>(initialCapacity: 4)
        for idx in 0..<7 {
            ring.prepend(idx)
        }

        let last = ring.remove(at: ring.endIndex.advanced(by: -1))
        XCTAssertEqual(0, last)
        XCTAssertEqual(1, ring.last)
    }

    func testRemoveAtTailIdx0() {
        var ring = CircularBuffer<Int>(initialCapacity: 4)
        ring.prepend(99)
        ring.prepend(98)
        XCTAssertEqual(2, ring.count)
        XCTAssertEqual(99, ring.remove(at: ring.endIndex.advanced(by: -1)))
        XCTAssertFalse(ring.isEmpty)
        XCTAssertEqual(1, ring.count)
        XCTAssertEqual(98, ring.last)
        XCTAssertEqual(98, ring.first)
    }

    func testRemoveAtFirstPosition() {
        var ring = CircularBuffer<Int>(initialCapacity: 4)
        for idx in 0..<7 {
            ring.prepend(idx)
        }

        let first = ring.remove(at: ring.startIndex)
        XCTAssertEqual(6, first)
        XCTAssertEqual(5, ring.first)
    }

    func testHarderExpansion() {
        var ring = CircularBuffer<Int>(initialCapacity: 3)
        XCTAssertEqual(ring.indices, ring.startIndex ..< ring.startIndex)

        ring.append(1)
        XCTAssertEqual(ring.count, 1)
        XCTAssertEqual(ring[ring.startIndex], 1)
        XCTAssertEqual(ring.indices, ring.startIndex ..< ring.startIndex.advanced(by: 1))

        ring.append(2)
        XCTAssertEqual(ring.count, 2)
        XCTAssertEqual(ring[ring.startIndex], 1)
        XCTAssertEqual(ring[ring.startIndex.advanced(by: 1)], 2)
        XCTAssertEqual(ring.indices, ring.startIndex ..< ring.startIndex.advanced(by: 2))

        ring.append(3)
        XCTAssertEqual(ring.count, 3)
        XCTAssertEqual(ring[ring.startIndex], 1)
        XCTAssertEqual(ring[ring.startIndex.advanced(by: 1)], 2)
        XCTAssertEqual(ring[ring.startIndex.advanced(by: 2)], 3)
        XCTAssertEqual(ring.indices, ring.startIndex ..< ring.startIndex.advanced(by: 3))


        XCTAssertEqual(1, ring.removeFirst())
        XCTAssertEqual(ring.count, 2)
        XCTAssertEqual(ring[ring.startIndex], 2)
        XCTAssertEqual(ring[ring.startIndex.advanced(by: 1)], 3)
        XCTAssertEqual(ring.indices, ring.startIndex ..< ring.startIndex.advanced(by: 2))

        XCTAssertEqual(2, ring.removeFirst())
        XCTAssertEqual(ring.count, 1)
        XCTAssertEqual(ring[ring.startIndex], 3)
        XCTAssertEqual(ring.indices, ring.startIndex ..< ring.startIndex.advanced(by: 1))

        ring.append(5)
        XCTAssertEqual(ring.count, 2)
        XCTAssertEqual(ring[ring.startIndex], 3)
        XCTAssertEqual(ring[ring.startIndex.advanced(by: 1)], 5)
        XCTAssertEqual(ring.indices, ring.startIndex ..< ring.startIndex.advanced(by: 2))

        ring.append(6)
        XCTAssertEqual(ring.count, 3)
        XCTAssertEqual(ring[ring.startIndex], 3)
        XCTAssertEqual(ring[ring.startIndex.advanced(by: 1)], 5)
        XCTAssertEqual(ring[ring.startIndex.advanced(by: 2)], 6)
        XCTAssertEqual(ring.indices, ring.startIndex ..< ring.startIndex.advanced(by: 3))

        ring.append(7)
        XCTAssertEqual(ring.count, 4)
        XCTAssertEqual(ring[ring.startIndex], 3)
        XCTAssertEqual(ring[ring.startIndex.advanced(by: 1)], 5)
        XCTAssertEqual(ring[ring.startIndex.advanced(by: 2)], 6)
        XCTAssertEqual(ring[ring.startIndex.advanced(by: 3)], 7)
        XCTAssertEqual(ring.indices, ring.startIndex ..< ring.startIndex.advanced(by: 4))
    }

    func testCollection() {
        var ring = CircularBuffer<Int>(initialCapacity: 4)
        XCTAssertEqual(ring.indices, ring.startIndex ..< ring.startIndex)
        XCTAssertEqual(0, ring.startIndex.distance(to: ring.endIndex))
        XCTAssertEqual(0, ring.endIndex.distance(to: ring.startIndex))

        for idx in 0..<5 {
            ring.append(idx)
        }

        XCTAssertFalse(ring.isEmpty)
        XCTAssertEqual(5, ring.count)

        XCTAssertEqual(ring.indices, ring.startIndex ..< ring.startIndex.advanced(by: 5))
        XCTAssertEqual(ring.startIndex, ring.startIndex)
        XCTAssertEqual(ring.endIndex, ring.startIndex.advanced(by: 5))

        XCTAssertEqual(ring.index(after: ring.startIndex.advanced(by: 1)), ring.startIndex.advanced(by: 2))
        XCTAssertEqual(ring.index(before: ring.startIndex.advanced(by: 3)), ring.startIndex.advanced(by: 2))
        
        let actualValues = [Int](ring)
        let expectedValues = [0, 1, 2, 3, 4]
        XCTAssertEqual(expectedValues, actualValues)
    }

    func testReplaceSubrange5ElementsWith1() {
        var ring = CircularBuffer<Int>(initialCapacity: 4)
        for idx in 0..<50 {
            ring.prepend(idx)
        }
        XCTAssertEqual(50, ring.count)
        ring.replaceSubrange(ring.startIndex.advanced(by: 20) ..< ring.startIndex.advanced(by: 25), with: [99])

        XCTAssertEqual(ring.count, 46)
        XCTAssertEqual(ring[ring.startIndex.advanced(by: 19)], 30)
        XCTAssertEqual(ring[ring.startIndex.advanced(by: 20)], 99)
        XCTAssertEqual(ring[ring.startIndex.advanced(by: 21)], 24)
    }

    func testReplaceSubrangeAllElementsWithFewerElements() {
        var ring = CircularBuffer<Int>(initialCapacity: 4)
        for idx in 0..<50 {
            ring.prepend(idx)
        }
        XCTAssertEqual(50, ring.count)

        ring.replaceSubrange(ring.startIndex..<ring.endIndex, with: [3,4])
        XCTAssertEqual(2, ring.count)
        XCTAssertEqual(3, ring.first)
        XCTAssertEqual(4, ring.last)
    }

    func testReplaceSubrangeEmptyRange() {
        var ring = CircularBuffer<Int>(initialCapacity: 4)
        for idx in 0..<50 {
            ring.prepend(idx)
        }
        XCTAssertEqual(50, ring.count)

        ring.replaceSubrange(ring.startIndex ..< ring.startIndex, with: [])
        XCTAssertEqual(50, ring.count)
    }

    func testReplaceSubrangeWithSubrangeLargerThanTargetRange() {
        var ring = CircularBuffer<Int>(initialCapacity: 4)
        for idx in 0..<5 {
            ring.prepend(idx)
        }
        XCTAssertEqual(5, ring.count)

        ring.replaceSubrange(ring.startIndex..<ring.endIndex, with: [10,11,12,13,14,15,16,17,18,19])
        XCTAssertEqual(10, ring.count)
        XCTAssertEqual(10, ring.first)
        XCTAssertEqual(19, ring.last)
    }

    func testReplaceSubrangeSameSize() {
        var ring = CircularBuffer<Int>(initialCapacity: 4)
        for idx in 0..<5 {
            ring.prepend(idx)
        }
        XCTAssertEqual(5, ring.count)
        XCTAssertEqual(4, ring.first)
        XCTAssertEqual(0, ring.last)

        var replacement = [Int]()
        for idx in 0..<5 {
            replacement.append(idx)
        }
        XCTAssertEqual(5, replacement.count)
        XCTAssertEqual(0, replacement.first)
        XCTAssertEqual(4, replacement.last)

        ring.replaceSubrange(ring.startIndex..<ring.endIndex, with: replacement)
        XCTAssertEqual(5, ring.count)
        XCTAssertEqual(0, ring.first)
        XCTAssertEqual(4, ring.last)
    }

    func testReplaceSubrangeReplaceBufferWithEmptyArray() {
        var ring = CircularBuffer<Int>(initialCapacity: 4)
        for idx in 0..<5 {
            ring.prepend(idx)
        }
        XCTAssertEqual(5, ring.count)
        XCTAssertEqual(4, ring.first)
        XCTAssertEqual(0, ring.last)

        ring.replaceSubrange(ring.startIndex..<ring.endIndex, with: [])
        XCTAssertTrue(ring.isEmpty)
    }

    func testWeCanDistinguishBetweenEmptyAndFull() {
        var ring = CircularBuffer<Int>(initialCapacity: 4)
        XCTAssertTrue(ring.isEmpty)
        for idx in 0..<4 {
            ring.append(idx)
        }
        XCTAssertEqual(4, ring.count)
        XCTAssertFalse(ring.isEmpty)
    }

    func testExpandZeroBasedRingWorks() {
        var ring = CircularBuffer<Int>(initialCapacity: 4)
        for idx in 0..<5 {
            ring.append(idx)
        }
        for idx in 0..<5 {
            XCTAssertEqual(idx, ring[ring.startIndex.advanced(by: idx)])
        }
    }

    func testExpandNonZeroBasedRingWorks() {
        var ring = CircularBuffer<Int>(initialCapacity: 4)
        for idx in 0..<4 {
            ring.append(idx)
        }
        /* the underlying buffer should now be filled from 0 to max */
        for idx in 0..<4 {
            XCTAssertEqual(idx, ring[ring.startIndex.advanced(by: idx)])
        }
        XCTAssertEqual(0, ring.removeFirst())
        /* now the first element is gone, ie. the ring starts at index 1 now */
        for idx in 0..<3 {
            XCTAssertEqual(idx + 1, ring[ring.startIndex.advanced(by: idx)])
        }
        ring.append(4)
        XCTAssertEqual(1, ring.first!)
        /* now the last element should be at ring position 0 */
        for idx in 0..<4 {
            XCTAssertEqual(idx + 1, ring[ring.startIndex.advanced(by: idx)])
        }
        /* and now we'll make it expand */
        ring.append(5)
        for idx in 0..<5 {
            XCTAssertEqual(idx + 1, ring[ring.startIndex.advanced(by: idx)])
        }
    }

    func testEmptyingExpandedRingWorks() {
        var ring = CircularBuffer<Int>(initialCapacity: 2)
        for idx in 0..<4 {
            ring.append(idx)
        }
        for idx in 0..<4 {
            XCTAssertEqual(idx, ring[ring.startIndex.advanced(by: idx)])
        }
        for idx in 0..<4 {
            XCTAssertEqual(idx, ring.removeFirst())
        }
        XCTAssertTrue(ring.isEmpty)
        XCTAssertNil(ring.first)
    }

    func testChangeElements() {
        var ring = CircularBuffer<Int>(initialCapacity: 100)
        for idx in 0..<50 {
            ring.append(idx)
        }
        var changes: [(Int, Int)] = []
        for (idx, element) in ring.enumerated() {
            XCTAssertEqual(idx, element)
            changes.append((idx, element * 2))
        }
        for change in changes {
            ring[ring.startIndex.advanced(by: change.0)] = change.1
        }
        for (idx, element) in ring.enumerated() {
            XCTAssertEqual(idx * 2, element)
        }
    }

    func testSliceTheRing() {
        var ring = CircularBuffer<Int>(initialCapacity: 100)
        for idx in 0..<50 {
            ring.append(idx)
        }

        let slice = ring[ring.startIndex.advanced(by: 25) ..< ring.startIndex.advanced(by: 30)]
        for (idx, element) in slice.enumerated() {
            XCTAssertEqual(ring.startIndex.advanced(by: idx + 25), ring.startIndex.advanced(by: element))
        }
    }

    func testCount() {
        var ring = CircularBuffer<Int>(initialCapacity: 4)
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

        XCTAssertEqual(3, ring.headIdx.backingIndex)
        XCTAssertEqual(1, ring.tailIdx.backingIndex)
        XCTAssertEqual(2, ring.count)
        XCTAssertEqual(4, ring.removeFirst())
        XCTAssertEqual(5, ring.removeFirst())
        XCTAssertEqual(0, ring.count)
        XCTAssertTrue(ring.isEmpty)
    }

    func testFirst() {
        var ring = CircularBuffer<Int>(initialCapacity: 3)
        XCTAssertNil(ring.first)
        ring.append(1)
        XCTAssertEqual(1, ring.first)
        XCTAssertEqual(1, ring.removeFirst())
        XCTAssertNil(ring.first)
    }

    func testLast() {
        var ring = CircularBuffer<Int>(initialCapacity: 3)
        XCTAssertNil(ring.last)
        ring.prepend(1)
        XCTAssertEqual(1, ring.last)
        XCTAssertEqual(1, ring.removeLast())
        XCTAssertNil(ring.last)
        XCTAssertEqual(0, ring.count)
        XCTAssertTrue(ring.isEmpty)
    }

    func testRemoveLast() {
        var ring = CircularBuffer<Int>(initialCapacity: 3)
        XCTAssertNil(ring.last)
        ring.append(1)
        ring.prepend(0)
        XCTAssertEqual(1, ring.last)
        XCTAssertEqual(1, ring.removeLast())
        XCTAssertEqual(0, ring.last)
    }

    func testRemoveLastCountElements() {
        var ring = CircularBuffer<Int>(initialCapacity: 3)
        XCTAssertNil(ring.last)
        ring.append(1)
        ring.prepend(0)
        XCTAssertEqual(1, ring.last)
        ring.removeLast(2)
        XCTAssertTrue(ring.isEmpty)
    }

    func testRemoveLastElements() {
        var ring = CircularBuffer<Int>(initialCapacity: 10)
        XCTAssertNil(ring.last)
        for i in 0 ..< 20 {
            ring.prepend(i)
        }
        XCTAssertEqual(20, ring.count)
        XCTAssertEqual(19, ring.first)
        XCTAssertEqual(0, ring.last)
        ring.removeLast(10)
        XCTAssertEqual(10, ring.count)
        XCTAssertEqual(19, ring.first)
        XCTAssertEqual(10, ring.last)
    }
    
    func testOperateOnBothSides() {
        var ring = CircularBuffer<Int>(initialCapacity: 3)
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
        var ring = CircularBuffer<Int>(initialCapacity: 3)
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
        var ring = CircularBuffer<Int>(initialCapacity: 2)
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
        var ring = CircularBuffer<Int>(initialCapacity: 2)
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

    func testBufferManaged() {
        var ring = CircularBuffer<Int>(initialCapacity: 2)
        ring.append(1)
        XCTAssertEqual(ring.capacity, 2)

        // Now we want to replace the last subrange with two elements. This should
        // force an increase in size.
        ring.replaceSubrange(ring.startIndex ..< ring.startIndex.advanced(by: 1), with: [3, 4])
        XCTAssertEqual(ring.capacity, 4)
    }

    func testDoesNotExpandCapacityNeedlesslyWhenInserting() {
        var ring = CircularBuffer<Int>(initialCapacity: 4)
        let capacity0 = ring.capacity
        XCTAssertGreaterThanOrEqual(capacity0, 4)
        XCTAssertLessThan(capacity0, 16)

        ring.insert(0, at: ring.startIndex)
        let capacity1 = ring.capacity
        XCTAssertEqual(capacity0, capacity1)

        ring.insert(1, at: ring.startIndex)
        let capacity2 = ring.capacity
        XCTAssertEqual(capacity0, capacity2)

        ring.insert(2, at: ring.startIndex)
        let capacity3 = ring.capacity
        XCTAssertEqual(capacity0, capacity3)
    }

    func testDoesNotExpandCapacityNeedlesslyWhenAppending() {
        var ring = CircularBuffer<Int>(initialCapacity: 4)
        let capacity0 = ring.capacity
        XCTAssertGreaterThanOrEqual(capacity0, 4)
        XCTAssertLessThan(capacity0, 16)

        ring.append(0)
        let capacity1 = ring.capacity
        XCTAssertEqual(capacity0, capacity1)

        ring.append(1)
        let capacity2 = ring.capacity
        XCTAssertEqual(capacity0, capacity2)

        ring.append(2)
        let capacity3 = ring.capacity
        XCTAssertEqual(capacity0, capacity3)
    }

    func testExpandRemoveAllKeepingAndNotKeepingCapacityAndExpandAgain() {
        for shouldKeepCapacity in [false, true] {
            var ring = CircularBuffer<Int>(initialCapacity: 4)

            (0..<16).forEach { ring.append($0) }
            (0..<4).forEach { _ in ring.removeFirst() }
            (16..<20).forEach { ring.append($0) }
            XCTAssertEqual(Array(4..<20), Array(ring))

            ring.removeAll(keepingCapacity: shouldKeepCapacity)

            (0..<8).forEach { ring.append($0) }
            (0..<4).forEach { _ in ring.removeFirst() }
            (8..<64).forEach { ring.append($0) }

            XCTAssertEqual(Array(4..<64), Array(ring))
        }
    }

    func testRemoveAllNilsOutTheContents() {
        class Dummy {}

        weak var dummy1: Dummy? = nil
        weak var dummy2: Dummy? = nil
        weak var dummy3: Dummy? = nil
        weak var dummy4: Dummy? = nil
        weak var dummy5: Dummy? = nil
        weak var dummy6: Dummy? = nil
        weak var dummy7: Dummy? = nil
        weak var dummy8: Dummy? = nil

        var ring: CircularBuffer<Dummy> = .init(initialCapacity: 4)

        ({
            for _ in 0..<2 {
                ring.append(Dummy())
            }

            dummy1 = ring.dropFirst(0).first
            dummy2 = ring.dropFirst(1).first

            XCTAssertNotNil(dummy1)
            XCTAssertNotNil(dummy2)

            ring.removeFirst()

            for _ in 2..<8 {
                ring.append(Dummy())
            }

            dummy3 = ring.dropFirst(1).first
            dummy4 = ring.dropFirst(2).first
            dummy5 = ring.dropFirst(3).first
            dummy6 = ring.dropFirst(4).first
            dummy7 = ring.dropFirst(5).first
            dummy8 = ring.dropFirst(6).first

            XCTAssertNotNil(dummy3)
            XCTAssertNotNil(dummy4)
            XCTAssertNotNil(dummy5)
            XCTAssertNotNil(dummy6)
            XCTAssertNotNil(dummy7)
            XCTAssertNotNil(dummy8)
        })()

        XCTAssertNotNil(dummy2)
        XCTAssertNotNil(dummy3)
        XCTAssertNotNil(dummy4)
        XCTAssertNotNil(dummy5)
        XCTAssertNotNil(dummy6)
        XCTAssertNotNil(dummy7)
        XCTAssertNotNil(dummy8)

        ring.removeAll(keepingCapacity: true)

        assert(dummy1 == nil, within: .seconds(1))
        assert(dummy2 == nil, within: .seconds(1))
        assert(dummy3 == nil, within: .seconds(1))
        assert(dummy4 == nil, within: .seconds(1))
        assert(dummy5 == nil, within: .seconds(1))
        assert(dummy6 == nil, within: .seconds(1))
        assert(dummy7 == nil, within: .seconds(1))
        assert(dummy8 == nil, within: .seconds(1))
    }
    
    func testIntIndexing() {
        var ring = CircularBuffer<Int>()
        for i in 0 ..< 5 {
            ring.append(i)
            XCTAssertEqual(ring[offset: i], i)
        }
        
        XCTAssertEqual(ring[ring.startIndex], ring[offset :0])
        XCTAssertEqual(ring[ring.index(before: ring.endIndex)], ring[offset: 4])
        
        ring[offset: 1] = 10
        XCTAssertEqual(ring[ring.index(after: ring.startIndex)], 10)
    }
    
    func testIndexDistance() {
        let index1 = CircularBuffer<Int>.Index(backingIndex: 0, backingIndexOfHead: 0, backingCount: 4)
        let index2 = CircularBuffer<Int>.Index(backingIndex: 1, backingIndexOfHead: 0, backingCount: 4)
        XCTAssertEqual(index1.distance(to: index2), 1)
        
        let index3 = CircularBuffer<Int>.Index(backingIndex: 2, backingIndexOfHead: 1, backingCount: 4)
        let index4 = CircularBuffer<Int>.Index(backingIndex: 0, backingIndexOfHead: 1, backingCount: 4)
        XCTAssertEqual(index3.distance(to: index4), 2)
        
        let index5 = CircularBuffer<Int>.Index(backingIndex: 0, backingIndexOfHead: 1, backingCount: 4)
        let index6 = CircularBuffer<Int>.Index(backingIndex: 2, backingIndexOfHead: 1, backingCount: 4)
        XCTAssertEqual(index5.distance(to: index6), -2)
        
        let index7 = CircularBuffer<Int>.Index(backingIndex: 0, backingIndexOfHead: 3, backingCount: 4)
        let index8 = CircularBuffer<Int>.Index(backingIndex: 2, backingIndexOfHead: 3, backingCount: 4)
        XCTAssertEqual(index7.distance(to: index8), 2)
    }
    
    func testIndexAdvancing() {
        let index1 = CircularBuffer<Int>.Index(backingIndex: 0, backingIndexOfHead: 0, backingCount: 4)
        let index2 = index1.advanced(by: 1)
        XCTAssertEqual(index2.backingIndex, 1)
        XCTAssertEqual(index2.isIndexGEQHeadIndex, true)
        
        let index3 = CircularBuffer<Int>.Index(backingIndex: 3, backingIndexOfHead: 2, backingCount: 4)
        let index4 = index3.advanced(by: 1)
        XCTAssertEqual(index4.backingIndex, 0)
        XCTAssertEqual(index4.isIndexGEQHeadIndex, false)
        
        let index5 = CircularBuffer<Int>.Index(backingIndex: 0, backingIndexOfHead: 1, backingCount: 4)
        let index6 = index5.advanced(by: -1)
        XCTAssertEqual(index6.backingIndex, 3)
        XCTAssertEqual(index6.isIndexGEQHeadIndex, true)
        
        let index7 = CircularBuffer<Int>.Index(backingIndex: 2, backingIndexOfHead: 1, backingCount: 4)
        let index8 = index7.advanced(by: -1)
        XCTAssertEqual(index8.backingIndex, 1)
        XCTAssertEqual(index8.isIndexGEQHeadIndex, true)
    }
}
