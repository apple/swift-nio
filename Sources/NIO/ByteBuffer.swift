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
import Foundation


public struct ByteBufferAllocator {
    
    public init() {}
    public func buffer(capacity: Int) throws -> ByteBuffer {
        return try buffer(capacity: capacity, maxCapacity: Int.max)
    }
    
    public func buffer(capacity: Int, maxCapacity: Int) throws -> ByteBuffer {
        return try ByteBuffer(allocator: self, startingCapacity: capacity, maxCapacity: maxCapacity)
    }
}

public struct ByteBuffer { // TODO: Equatable, Comparable

    enum ByteBufferError : Error {
        case maxCapacityExceeded
    }

    private var data: Data

    public private(set) var capacity = 0

    /**
         Adjusts the capacity of the buffer. If the new capacity is less than the current
         capacity, the content of this buffer is truncated. If the new capacity is greater than the
         current capacity, the buffer is appended with unspecified data of length newCapacity - currentCapacity
     */
    public mutating func changeCapacity(to newCapacity: Int) throws {
        let result = ensureWritable(bytesNeeded: newCapacity - writerIndex, expandIfRequired: true)
        switch result {
        case (true, _):
            return
        default:
            throw ByteBufferError.maxCapacityExceeded // TODO: Possibly other reasons, yeah?
        }
    }
    
    /**
     Returns the maximum allowed capacity of this buffer.  If a user attempts to increase the
     capacity of this buffer beyond the maximum capacity, an Error will be thrown
     */ // TODO: Specify the Error
    public private(set) var maxCapacity = Int.max
    
    // The allocator that created this buffer, if any
    public private(set) var allocator: ByteBufferAllocator?


    public private(set) var readerIndex = 0, markedReaderIndex = 0
    public private(set) var writerIndex = 0, markedWriterIndex = 0

    var writableBytes: Int { return self.capacity - self.writerIndex }
    var readableBytes: Int { return self.writerIndex - self.readerIndex }
    
    public init(allocator: ByteBufferAllocator, startingCapacity: Int, maxCapacity: Int) throws {
        precondition(startingCapacity >= 0)
        precondition(startingCapacity <= maxCapacity)

        self.allocator = allocator
        self.maxCapacity = maxCapacity
        self.data = Data(capacity: startingCapacity)
        self.capacity = startingCapacity
    }

    
    /**
     Discards the bytes between the 0th index and readerIndex. It moves the bytes between readerIndex and
     writerIndex to the 0th index, and sets readerIndex to 0 and writerIndex to oldWriterIndex - oldReaderIndex
     */
    public mutating func discardReadBytes() {
        // TODO
    }

    // Tries to make sure that the number of writable bytes is equal to or greater than the specified value.
    public mutating func ensureWritable(bytesNeeded: Int) throws {
        if !ensureWritable(bytesNeeded: bytesNeeded, expandIfRequired: false).enoughSpace {
            throw ByteBufferError.maxCapacityExceeded
        }
    }

    @discardableResult public mutating func ensureWritable(bytesNeeded: Int, expandIfRequired: Bool)
        -> (enoughSpace: Bool, capacityIncreased: Bool) {
            if bytesNeeded <= writableBytes {
                return (enoughSpace: true, capacityIncreased: false)
            }

            let deficit = bytesNeeded - writableBytes

            if capacity + deficit > maxCapacity {
                return (enoughSpace: false, capacityIncreased: false)
            }

            let oldData = self.data

            data = Data(capacity: capacity + deficit) // TODO: alloc at nearest power of two
            capacity += deficit

            data.append(oldData)

            return (enoughSpace: true, capacityIncreased: true)
    }

    
    
    public func withReadPointer<T>(body: (UnsafePointer<UInt8>, Int) -> T) -> T {
        return data.withUnsafeBytes({ body($0 + readerIndex, readableBytes) })
    }
    
    public func withReadPointer<T>(body: (UnsafePointer<UInt8>, Int) throws -> T) throws -> T {
        return try data.withUnsafeBytes({ try body($0 + readerIndex, readableBytes) })
    }

    public func withWritePointer<T>(body: (UnsafePointer<UInt8>, Int) -> T) -> T {
        return data.withUnsafeBytes({ body($0 + writerIndex, writableBytes) })
    }

    public func withWritePointer<T>(body: (UnsafePointer<UInt8>, Int) throws -> T) throws -> T {
        return try data.withUnsafeBytes({ try body($0 + writerIndex, writableBytes) })
    }

    // Mutable versions for writing to the buffer. body function returns the number of bytes written and writerIndex
    // will be automatically moved.

    public mutating func withMutableWritePointer(body: (UnsafeMutablePointer<UInt8>, Int) -> Int?) -> Int? {
        let bytesWritten = data.withUnsafeMutableBytes({ return body($0 + writerIndex, writableBytes) })

        advanceWriterIndex(bytesWritten ?? 0)

        return bytesWritten
    }

    public mutating func withMutableWritePointer(body: (UnsafeMutablePointer<UInt8>, Int) throws -> Int?) throws -> Int? {
        let bytesWritten = try data.withUnsafeMutableBytes({ return try body($0 + writerIndex, writableBytes) })

        advanceWriterIndex(bytesWritten ?? 0)

        return bytesWritten
    }

    public mutating func withMutableReadPointer(body: (UnsafeMutablePointer<UInt8>, Int) -> Int?) -> Int? {
        let bytesWritten = data.withUnsafeMutableBytes({ return body($0 + readerIndex, readableBytes) })

        advanceReaderIndex(bytesWritten ?? 0)

        return bytesWritten
    }

    public mutating func withMutableReadPointer(body: (UnsafeMutablePointer<UInt8>, Int) throws -> Int?) throws -> Int? {
        let bytesWritten = try data.withUnsafeMutableBytes({ return try body($0 + readerIndex, readableBytes) })

        advanceReaderIndex(bytesWritten ?? 0)

        return bytesWritten
    }


    // Provides the read portion of the buffer as Data.
    public func withReadData<T>(body: (Data) -> T) -> T {
        return body(data)
    }
    
    // TODO: get/skip/set for all the type conversions
    
    // TODO: indexOf, bytesBefore, forEachByte, copy, reatinedSlice/slice, duplicate, direct buffer access?, backing byte array access?
    
    // TODO: Generics to avoid this?
    public mutating func write(string: String) {
        let _ = withMutableWritePointer { (writePtr: UnsafeMutablePointer<UInt8>, size: Int) -> Int in
            // TODO: Can we avoid the double copy? getBytes seems almost, but not quite right.
            if let data = string.data(using: .utf8) {
                let _ = data.withUnsafeBytes { writePtr.assign(from: $0, count: 1) }
                return data.count
            } else {
                return 0
            }
        }
    }
    
    /**
     Marks the current readerIndex in this buffer. You can reposition the current readerIndex to the marked
     readerIndex by calling resetReaderIndex(). The initial value of the marked readerIndex is 0.
     */
    public mutating func markReaderIndex() {
        markedReaderIndex = readerIndex
    }
    
    /**
     Moves the current readerIndex to the marked readerIndex in this buffer.
     */
    public mutating func resetReaderIndex() {
        moveReaderIndex(to: markedReaderIndex)
    }
    
    /**
     Marks the current writerIndex in this buffer. You can reposition the current writerIndex to the marked
     writerIndex by calling resetWriterIndex(). The initial value of the marked writerIndex is 0.
     */
    public mutating func markWriterIndex() {
        markedWriterIndex = writerIndex
    }
    
    /**
     Moves the current writerIndex to the marked writerIndex in this buffer.
     If the readerIndex is greater than the marked writerIndex nothing is returned.
     */
    public mutating func resetWriterIndex() {
        moveWriterIndex(to: markedWriterIndex)
    }
    
    private mutating func moveReaderIndex(to newIndex: Int) {
        precondition(newIndex >= 0 && newIndex <= writerIndex)
        
        readerIndex = newIndex
    }
    
    private mutating func moveWriterIndex(to newIndex: Int) {
        precondition(newIndex >= readerIndex && newIndex <= capacity)
        
        writerIndex = newIndex
    }
    
    private mutating func advanceWriterIndex(_ count: Int) {
        moveWriterIndex(to: writerIndex + count)
    }
    
    private mutating func advanceReaderIndex(_ count: Int) {
        moveReaderIndex(to: readerIndex + count)
    }
    
    /**
     Sets the readerIndex and writerIndex of this buffer in one shot. This method is useful when you have to
     worry about the invocation order of settings both indicies.
     */
    private mutating func moveIndicies(reader: Int, writer: Int) {
        precondition(0 <= reader && reader <= writer && writer <= capacity)
        
        readerIndex = reader
        writerIndex = writer
    }
}
