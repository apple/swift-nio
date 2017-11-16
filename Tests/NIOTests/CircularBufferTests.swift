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
import NIO

class CircularBufferTests: XCTestCase {
    func testTrivial() {
        var ring = CircularBuffer<Int>(initialRingCapacity: 8)
        ring.append(1)
        XCTAssertEqual(1, ring.removeFirst())
    }
    
    func testAddRemoveInALoop() {
        var ring = CircularBuffer<Int>(initialRingCapacity: 8)
        for f in 0..<1000 {
            ring.append(f)
            XCTAssertEqual(f, ring.removeFirst())
        }
    }
    
    func testAddAllRemoveAll() {
        var ring = CircularBuffer<Int>(initialRingCapacity: 8)
        for f in 0..<1000 {
            ring.append(f)
        }
        for f in 0..<1000 {
            XCTAssertEqual(f, ring.removeFirst())
        }
    }
    
    func testHarderExpansion() {
        var ring = CircularBuffer<Int>(initialRingCapacity: 3, expandSize: 3)
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
        var ring = CircularBuffer<Int>(initialRingCapacity: 4, expandSize: 4)
        XCTAssertEqual(ring.indices, 0..<0)
        XCTAssertEqual(ring.startIndex, 0)
        XCTAssertEqual(ring.endIndex, 0)

        for idx in 0..<5 {
            ring.append(idx)
        }

        XCTAssertEqual(ring.indices, 0..<5)
        XCTAssertEqual(ring.startIndex, 0)
        XCTAssertEqual(ring.endIndex, 5)

        XCTAssertEqual(ring.index(after: 1), 2)

        let actualValues = [Int](ring)
        let expectedValues = [0, 1, 2, 3, 4]
        XCTAssertEqual(expectedValues, actualValues)
    }
}
