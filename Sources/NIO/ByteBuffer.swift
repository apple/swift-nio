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
    public let alignment: UInt

    public init(alignTo alignment: UInt = 1) {
        precondition(alignment > 0, "alignTo must be greater or equal to 1 (is \(alignment))")
        self.alignment = alignment
    }
    
    public func buffer(capacity: Int) throws -> ByteBuffer {
        return try buffer(capacity: capacity, maxCapacity: Int.max)
    }
    
    public func buffer(capacity: Int, maxCapacity: Int) throws -> ByteBuffer {
        return try ByteBuffer(allocator: self, startingCapacity: capacity, maxCapacity: maxCapacity)
    }
    
    public func buffer(wrapped: Data) -> ByteBuffer {
        return buffer(wrapped: wrapped, offset: 0, length: wrapped.count)
    }
    
    public func buffer(wrapped: Data, offset: Int, length: Int) -> ByteBuffer {
        return buffer(wrapped: wrapped, offset: offset, length: length, maxCapacity: Int.max)
    }
    
    public func buffer(wrapped: Data, offset: Int, length: Int, maxCapacity: Int) -> ByteBuffer {
        return ByteBuffer(allocator: self, data: wrapped, offset: offset, length: length, maxCapacity: Int.max)
    }
}

extension UInt64 {
    public func nextPowerOf2() -> UInt64 {
        guard self > 0 else {
            return 1
        }

        var n = self

        n -= 1
        n |= n >> 1
        n |= n >> 2
        n |= n >> 4
        n |= n >> 8
        n |= n >> 16
        n |= n >> 32
        n += 1

        return n
    }
}

public enum Endianess {
    public static let host: Endianess = hostEndianess0()
    
    private static func hostEndianess0() -> Endianess {
        let number: UInt32 = 0x12345678
        let converted = number.bigEndian
        if number == converted {
            return .Big
        } else {
            return .Little
        }
    }

    case Big
    case Little
}

public struct ByteBuffer : Equatable { // TODO: Comparable
    
    public static func ==(lhs: ByteBuffer, rhs: ByteBuffer) -> Bool {
        guard lhs.readableBytes == rhs.readableBytes else {
            return false
        }

        return lhs.withReadPointer { lhsPtr, lhsSize in
                rhs.withReadPointer { rhsPtr, rhsSize in
                    // Shouldn't get here otherwise because of readableBytes check
                    assert(rhsSize == lhsSize)
                    return memcmp(lhsPtr, rhsPtr, lhsSize) == 0
                }
            }
    }

    private static func reallocatedData(minimumCapacity: Int, source: Data?, allocator: ByteBufferAllocator) -> Data {
        let newCapacity = Int(UInt64(minimumCapacity).nextPowerOf2())
        var newData = Data(bytesNoCopy: UnsafeMutableRawPointer.allocate(bytes: newCapacity,
                                                                         alignedTo: Int(allocator.alignment)),
                           count: newCapacity,
                           deallocator: Data.Deallocator.custom({ $0.deallocate(bytes: $1,
                                                                                alignedTo: Int(allocator.alignment)) }))
        if let source = source {
            newData.replaceSubrange(0..<source.count, with: source)
        }
        return newData
    }

    enum ByteBufferError : Error {
        case maxCapacityExceeded
    }

    // Mark as internal so we can access it in tests.
    var backingData: Data
    
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
    public private(set) var allocator: ByteBufferAllocator


    private let offset: Int
    public private(set) var capacity: Int

    public private(set) var readerIndex = 0, markedReaderIndex = 0
    public private(set) var writerIndex = 0, markedWriterIndex = 0

    public var writableBytes: Int { return self.capacity - self.writerIndex }
    public var readableBytes: Int { return self.writerIndex - self.readerIndex }
    
    public init(allocator: ByteBufferAllocator, startingCapacity: Int, maxCapacity: Int) throws {
        precondition(startingCapacity >= 0)
        precondition(startingCapacity <= maxCapacity)

        self.allocator = allocator
        self.maxCapacity = maxCapacity
        self.backingData = ByteBuffer.reallocatedData(minimumCapacity: startingCapacity, source: nil, allocator: allocator)
        self.offset = 0
        self.capacity = backingData.count
    }
    
    init(allocator: ByteBufferAllocator, data: Data, offset: Int, length: Int, maxCapacity: Int) {
        precondition(offset >= 0)
        precondition(length <= maxCapacity)
        precondition(data.count >= length - offset)

        self.allocator = allocator
        self.maxCapacity = maxCapacity
        self.writerIndex = length
        self.offset = offset
        self.backingData = data
        self.capacity = length
    }

    /**
     Discards the bytes between the 0th index and readerIndex. It moves the bytes between readerIndex and
     writerIndex to the 0th index, and sets readerIndex to 0 and writerIndex to oldWriterIndex - oldReaderIndex
     */
    @discardableResult public mutating func discardReadBytes() -> Bool {
        guard readerIndex > 0 else {
            return false
        }
        backingData.withUnsafeMutableBytes { (p: UnsafeMutablePointer<UInt8>) -> Void in
            p.advanced(by: offset).assign(from: p.advanced(by: applyOffset(readerIndex)), count: readableBytes)
        }
        writerIndex = writerIndex - readerIndex
        readerIndex = 0
        return true
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
            
            guard expandIfRequired else {
                return (enoughSpace: false, capacityIncreased: false)
            }

            let deficit = bytesNeeded - writableBytes

            if capacity + deficit > maxCapacity {
                return (enoughSpace: false, capacityIncreased: false)
            }

            self.backingData = ByteBuffer.reallocatedData(minimumCapacity: capacity + deficit,
                                                   source: self.backingData,
                                                   allocator: self.allocator)
            self.capacity = backingData.count
            return (enoughSpace: true, capacityIncreased: true)
    }
    

    private func applyOffset(_ index: Int) -> Int {
        return index + offset
    }
    
    public func withReadPointer<T>(body: (UnsafePointer<UInt8>, Int) throws -> T) rethrows -> T {
        return try backingData.withUnsafeBytes({ try body($0.advanced(by: applyOffset(readerIndex)), readableBytes) })
    }

    // Provides the read portion of the buffer as Data slice.
    public func withReadDataSlice<T>(body: (MutableSlice<Data>) throws -> T) rethrows -> T {
        let data = self.backingData
        return try body(data[Range(readerIndex..<readerIndex+readableBytes)])
    }

    public func withWritePointer<T>(body: (UnsafePointer<UInt8>, Int) throws -> T) rethrows -> T {
        return try backingData.withUnsafeBytes({ try body($0.advanced(by: applyOffset(writerIndex)), writableBytes) })
    }

    // Mutable versions for writing to the buffer. body function returns the number of bytes written and writerIndex
    // will be automatically moved.

    //
    public mutating func withMutableWritePointer(body: (UnsafeMutablePointer<UInt8>, Int) throws -> Int?) rethrows -> Int? {
        let bytesWritten = try backingData.withUnsafeMutableBytes({ return try body($0.advanced(by: applyOffset(writerIndex)), writableBytes) })

        advanceWriterIndex(bytesWritten ?? 0)

        return bytesWritten
    }

    // body function should return the number of bytes consumed, if any. 0 indicates EOF. Result from calling body is returned.
    public mutating func withMutableReadPointer(body: (UnsafeMutablePointer<UInt8>, Int) throws -> Int?) rethrows -> Int? {
        let bytesWritten = try backingData.withUnsafeMutableBytes { try body($0.advanced(by: applyOffset(readerIndex)), readableBytes) }

        advanceReaderIndex(bytesWritten ?? 0)

        return bytesWritten
    }

    private mutating func expandIfNeeded(index: Int, size: Int) -> Bool {
        let v = capacity - (index + size)
        
        guard v >= 0 && ensureWritable(bytesNeeded: -v, expandIfRequired: true).enoughSpace else {
            return false
        }
        return true
    }

    private func toEndianess<T: EndianessInteger> (value: T, endianess: Endianess) -> T {
        switch endianess {
        case .Little:
            return value.littleEndian
        case .Big:
            return value.bigEndian
        }
    }

    public mutating func read<T: EndianessInteger>(endianess: Endianess = .Big) -> T? {
        if let int: T = get0(at: applyOffset(readerIndex), limit: applyOffset(writerIndex), endianess: endianess) {
            readerIndex += MemoryLayout<T>.size
            return int
        }
        return nil
    }
    
    public func get<T: EndianessInteger>(at index: Int, endianess: Endianess = .Big) -> T? {
        return get0(at: applyOffset(index), limit: capacity, endianess: endianess)
    }
    
    private func get0<T: EndianessInteger>(at index: Int, limit: Int, endianess: Endianess = .Big) -> T? {
        guard index + MemoryLayout<T>.size <= limit else {
            return nil
        }
        let intBits = backingData.withUnsafeBytes({(bytePointer: UnsafePointer<UInt8>) -> T in
            bytePointer.advanced(by: index).withMemoryRebound(to: T.self, capacity: 1) { pointer in
                return pointer.pointee
            }
        })
        return toEndianess(value: intBits, endianess: endianess)
    }
    
    
    public mutating func set<T: EndianessInteger>(integer: T, at index: Int, endianess: Endianess = .Big) -> Int? {
        let size = MemoryLayout<T>.size
        if expandIfNeeded(index: index, size: size) {
            var v = toEndianess(value: integer, endianess: endianess)
            
            withUnsafePointer(to: &v) { valPointer in
                valPointer.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<T>.size) { p in
                    backingData.withUnsafeMutableBytes({ (dataPointer: UnsafeMutablePointer<UInt8>) -> Void in
                        dataPointer.advanced(by: applyOffset(index)).assign(from: p, count: MemoryLayout<T>.size)
                    })
                }
            }
            return size
        }
        return nil
    }
    
    @discardableResult
    public mutating func write<T: EndianessInteger>(integer: T, endianess: Endianess = .Big) -> Int? {
        if let bytes = set(integer: integer, at: writerIndex, endianess: endianess) {
            writerIndex += bytes
            return bytes
        }
        return nil
    }
    
    @discardableResult
    public mutating func set(bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Int? {
        if expandIfNeeded(index: index, size: bytes.count) {
            let idx = applyOffset(index)
            self.backingData.replaceSubrange(idx..<idx + bytes.count, with: bytes)
            return bytes.count
        }
        return nil
    }

    @discardableResult
    public mutating func set(data: Data, at index: Int) -> Int? {
        if expandIfNeeded(index: index, size: data.count) {
            let idx = applyOffset(index)
            self.backingData.replaceSubrange(idx..<idx + data.count, with: data)
            return data.count
        }
        return nil
    }

    @discardableResult
    public mutating func write(data: Data) -> Int? {
        if let bytes = set(data: data, at: writerIndex) {
            writerIndex += bytes
            return bytes
        }
        return nil
    }
    
    public mutating func get(at index: Int, length: Int) -> Data? {
        guard length <= capacity - index else {
            return nil
        }
        let idx = applyOffset(index)
        return backingData.subdata(in: idx..<idx + length)
    }
    
    public mutating func read(length: Int) -> Data? {
        if let data = get(at: readerIndex, length: length) {
            readerIndex += data.count
            return data
        }
        return nil
    }
    
    // TODO: indexOf, bytesBefore, forEachByte, backing byte array access?
    
    // TODO: Generics to avoid this?

    @discardableResult
    public mutating func write(staticString string: StaticString) -> Int? {
        if let bytes = set(staticString: string, at: writerIndex) {
            writerIndex += bytes
            return bytes
        }
        return nil
    }

    @discardableResult
    public mutating func write(string: String) -> Int? {
        if let bytes = set(string: string, at: writerIndex) {
            writerIndex += bytes
            return bytes
        }
        return nil
    }
    
    @discardableResult
    public mutating func set(staticString string: StaticString, at index: Int) -> Int? {
        return string.withUTF8Buffer { buffer in
            print("set buffer at \(index)")
            return self.set(bytes: buffer, at: index)
        }
    }

    @discardableResult
    public mutating func set(string: String, at index: Int) -> Int? {
        let utf8 = string.utf8
        let count = utf8.count
        if expandIfNeeded(index: index, size: count) {
            let idx = applyOffset(index)
            backingData.replaceSubrange(idx..<idx + count, with: utf8)
            return count
        }
        return nil
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
    
    public mutating func skipBytes(num: Int) {
       moveReaderIndex(to: readerIndex + num)
    }

    /*
     Returns a slice of this buffer's sub-region
     */
    public func slice(from: Int, length: Int) -> ByteBuffer? {
        guard from + length <= capacity else {
            return nil
        }
        return ByteBuffer(allocator: allocator, data: backingData, offset: from, length: length, maxCapacity: maxCapacity)
    }
    
    /**
     Returns a slice of this buffer's readable bytes
     */
    public func slice() -> ByteBuffer {
        return slice(from: readerIndex, length: readableBytes)!
    }
    
    /**
     Returns a new slice of this buffer's sub-region starting at the current readerIndex and increases the readerIndex by the size of the new slice (= length).
     */
    public mutating func readSlice(length: Int) -> ByteBuffer? {
        if let buffer = slice(from: readerIndex, length: length) {
            skipBytes(num: length)
            return buffer
        }
        return nil
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

// Extensions to allow convert to different Endianess.

extension UInt8 : EndianessInteger {
    public var littleEndian: UInt8 {
        return self
    }

    public var bigEndian: UInt8 {
        return self
    }
}
extension UInt16 : EndianessInteger { }
extension UInt32 : EndianessInteger { }
extension UInt64 : EndianessInteger { }
extension Int8 : EndianessInteger {
    public var littleEndian: Int8 {
        return self
    }
    
    public var bigEndian: Int8 {
        return self
    }
}
extension Int16 : EndianessInteger { }
extension Int32 : EndianessInteger { }
extension Int64 : EndianessInteger { }

extension Bool {
    public var byte: UInt8 {
        if self {
            return 1
        }
        return 0
    }
}

#if swift(>=4.0)
public typealias NumericProtocol = Numeric
#else
public typealias NumericProtocol = Integer
#endif
public protocol EndianessInteger: NumericProtocol {

    /// Returns the big-endian representation of the integer, changing the
    /// byte order if necessary.
    var bigEndian: Self { get }
    
    /// Returns the little-endian representation of the integer, changing the
    /// byte order if necessary.
    var littleEndian: Self { get }
}
