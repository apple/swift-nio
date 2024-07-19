//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest

@testable import _NIODataStructures

public func getRandomNumbers(count: Int) -> [UInt8] {
    (0..<count).map { _ in
        UInt8.random(in: .min ... .max)
    }
}

class HeapTests: XCTestCase {
    func testSimple() throws {
        var h = Heap<Int>()
        h.append(3)
        h.append(1)
        h.append(2)
        XCTAssertEqual(1, h.removeRoot())
        XCTAssertTrue(h.checkHeapProperty())
    }

    func testSortedDesc() throws {
        var minHeap = Heap<Int>()

        let inputs = [16, 14, 10, 9, 8, 7, 4, 3, 2, 1]
        for input in inputs {
            minHeap.append(input)
            XCTAssertTrue(minHeap.checkHeapProperty())
        }
        var minHeapInputPtr = inputs.count - 1
        while let minE = minHeap.removeRoot() {
            XCTAssertEqual(minE, inputs[minHeapInputPtr])
            minHeapInputPtr -= 1
            XCTAssertTrue(minHeap.checkHeapProperty(), "\(minHeap.debugDescription)")
        }
        XCTAssertEqual(-1, minHeapInputPtr)
    }

    func testSortedAsc() throws {
        var minHeap = Heap<Int>()

        let inputs = Array([16, 14, 10, 9, 8, 7, 4, 3, 2, 1].reversed())
        for input in inputs {
            minHeap.append(input)
        }
        var minHeapInputPtr = 0
        while let minE = minHeap.removeRoot() {
            XCTAssertEqual(minE, inputs[minHeapInputPtr])
            minHeapInputPtr += 1
        }
        XCTAssertEqual(inputs.count, minHeapInputPtr)
    }

    func testAddAndRemoveRandomNumbers() throws {
        var minHeap = Heap<UInt8>()
        var minHeapLast = UInt8.min

        let N = 10

        for n in getRandomNumbers(count: N) {
            minHeap.append(n)
            XCTAssertTrue(minHeap.checkHeapProperty(), minHeap.debugDescription)

            XCTAssertEqual(Array(minHeap.sorted()), Array(minHeap))
        }

        for _ in 0..<N / 2 {
            let value = minHeap.removeRoot()!
            XCTAssertGreaterThanOrEqual(value, minHeapLast)
            minHeapLast = value

            XCTAssertTrue(minHeap.checkHeapProperty())

            XCTAssertEqual(Array(minHeap.sorted()), Array(minHeap))
        }

        minHeapLast = UInt8.min

        for n in getRandomNumbers(count: N) {
            minHeap.append(n)
            XCTAssertTrue(minHeap.checkHeapProperty(), minHeap.debugDescription)
        }

        for _ in 0..<N / 2 + N {
            let value = minHeap.removeRoot()!
            XCTAssertGreaterThanOrEqual(value, minHeapLast)
            minHeapLast = value

            XCTAssertTrue(minHeap.checkHeapProperty())
        }

        XCTAssertEqual(0, minHeap.underestimatedCount)
    }

    func testRemoveElement() throws {
        var h = Heap<Int>()
        for f in [84, 22, 19, 21, 3, 10, 6, 5, 20] {
            h.append(f)
        }
        _ = h.remove(value: 10)
        XCTAssertTrue(h.checkHeapProperty(), "\(h.debugDescription)")
    }
}

extension Heap {
    internal func checkHeapProperty() -> Bool {
        func checkHeapProperty(index: Int) -> Bool {
            let li = self.leftIndex(index)
            let ri = self.rightIndex(index)
            if index >= self.storage.count {
                return true
            } else {
                let me = self.storage[index]
                var lCond = true
                var rCond = true
                if li < self.storage.count {
                    let l = self.storage[li]
                    lCond = !self.comparator(l, me)
                }
                if ri < self.storage.count {
                    let r = self.storage[ri]
                    rCond = !self.comparator(r, me)
                }
                return lCond && rCond && checkHeapProperty(index: li) && checkHeapProperty(index: ri)
            }
        }
        return checkHeapProperty(index: 0)
    }
}
