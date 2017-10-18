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

public struct CircularBuffer<E>: CustomStringConvertible {
    private var buffer: ContiguousArray<E?>
    
    /* the capacity of the underlying buffer */
    /* private */ var bufferCapacity: Int
    
    /* how many slots of the underlying buffer are actually used */
    private var bufferLength = 0
    
    /* the index into the buffer of the first item */
    private var startIdx = 0
    
    /* the index into the buffer of the next free slot */
    private var endIdx = 0
    
    /* the number of items in the ring part of this buffer */
    private var ringLength = 0
    
    /* the capacity of the ring */
    private var ringCapacity: Int
    
    /* how many elements to add to the buffer by default if it's exhausted */
    private let expandSize: Int
    
    public init(initialRingCapacity: UInt, expandSize: UInt = 8) {
        self.bufferCapacity = Int(initialRingCapacity)
        self.ringCapacity = Int(initialRingCapacity)
        self.buffer = ContiguousArray<E?>(repeating: nil, count: Int(initialRingCapacity))
        self.expandSize = Int(expandSize)
    }
    
    public mutating func append(_ value: E) {
        let expandBuf: Bool
        let expandRing: Bool
        if self.ringCapacity != self.bufferCapacity {
            expandBuf = self.endIdx == 0
            expandRing = false
        } else if self.ringCapacity == self.ringLength {
            expandBuf = true
            expandRing = self.endIdx == 0
        } else {
            expandBuf = false
            expandRing = false
        }
        
        if expandBuf {
            self.endIdx = self.bufferCapacity
            let expansion: [E?] = Array(repeating: nil, count: self.expandSize)
            self.buffer.append(contentsOf: expansion)
            self.bufferCapacity += expansion.count
            if expandRing {
                self.ringCapacity = self.bufferCapacity
            }
        }
        
        self.buffer[self.endIdx] = value
        self.bufferLength += 1
        if self.endIdx < self.ringCapacity {
            self.ringLength += 1
        }
        self.endIdx = (self.endIdx + 1) % self.bufferCapacity
    }
    
    public mutating func removeFirst() -> E {
        precondition(self.bufferLength != 0)
        
        let value = self.buffer[self.startIdx]
        self.buffer[startIdx] = nil
        self.bufferLength -= 1
        self.ringLength -= 1
        if self.ringLength == 0 && self.bufferLength != 0 {
            self.startIdx = self.ringCapacity
            self.ringLength = self.bufferLength
            self.ringCapacity = self.bufferCapacity
        } else {
            self.startIdx = (self.startIdx + 1) % self.ringCapacity
        }
        
        return value!
    }
    
    public var first: E? {
        if self.isEmpty {
            return nil
        } else {
            return self.buffer[self.startIdx]
        }
    }
    
    public var isEmpty: Bool {
        return self.bufferLength == 0
    }
    
    public var count: Int {
        return self.bufferLength
    }
    
    private func bufferIndex(ofIndex index: Int) -> Int {
        if index < self.ringLength {
            return (self.startIdx + index) % self.ringCapacity
        } else {
            return self.ringCapacity + index - ringLength
        }
    }
    
    public subscript(index: Int) -> E {
        get {
            return self.buffer[self.bufferIndex(ofIndex: index)]!
        }
        set {
            self.buffer[self.bufferIndex(ofIndex: index)] = newValue
        }
    }
    
    public var indices: CountableRange<Int> {
        return 0..<self.ringLength
    }
    
    public var description: String {
        var desc = "[ "
        for el in self.buffer.enumerated() {
            if el.0 == self.startIdx {
                desc += "<"
            } else if el.0 == self.endIdx {
                desc += ">"
            }
            desc += el.1.map { "\($0) " } ?? "_ "
        }
        desc += "]"
        desc += " (bufferCapacity: \(self.bufferCapacity), bufferLength: \(self.bufferLength), ringCapacityacity: \(self.ringCapacity), ringLength: \(self.ringLength))"
        return desc
    }
}
