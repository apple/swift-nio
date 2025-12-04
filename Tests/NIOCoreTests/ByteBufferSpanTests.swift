//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import Testing

#if compiler(>=6.2)
@Suite
struct ByteBufferSpanTests {
    @Test
    @available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
    func testReadableBytesSpanOfEmptyByteBuffer() {
        let bb = ByteBuffer()
        #expect(bb.readableBytesSpan.byteCount == 0)
    }

    @Test
    @available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
    func testReadableBytesSpanOfSimpleBuffer() {
        let bb = ByteBuffer(string: "Hello, world!")
        #expect(bb.readableBytesSpan.byteCount == 13)
        let bytesEqual = bb.readableBytesSpan.elementsEqual("Hello, world!".utf8)
        #expect(bytesEqual)
    }

    @Test
    @available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
    func testReadableBytesSpanNotAtTheStart() {
        var bb = ByteBuffer(string: "Hello, world!")
        bb.moveReaderIndex(forwardBy: 5)
        #expect(bb.readableBytesSpan.byteCount == 8)
        let bytesEqual = bb.readableBytesSpan.elementsEqual(", world!".utf8)
        #expect(bytesEqual)
    }

    @Test
    @available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
    func testReadableBytesSpanOfSlice() {
        let first = ByteBuffer(string: "Hello, world!")
        let bb = first.getSlice(at: 5, length: 5)!
        #expect(bb.readableBytesSpan.byteCount == 5)
        let bytesEqual = bb.readableBytesSpan.elementsEqual(", wor".utf8)
        #expect(bytesEqual)
    }

    @Test
    @available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
    func testMutableReadableBytesSpanOfEmptyByteBuffer() {
        var bb = ByteBuffer()
        #expect(bb.mutableReadableBytesSpan.byteCount == 0)
    }

    @Test
    @available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
    func testMutableReadableBytesSpanOfSimpleBuffer() {
        var bb = ByteBuffer(string: "Hello, world!")
        #expect(bb.mutableReadableBytesSpan.byteCount == 13)
        let bytesEqual = bb.mutableReadableBytesSpan.elementsEqual("Hello, world!".utf8)
        #expect(bytesEqual)

        var readableBytes = bb.mutableReadableBytesSpan
        readableBytes.storeBytes(of: UInt8(ascii: "o"), toByteOffset: 5, as: UInt8.self)

        #expect(String(buffer: bb) == "Helloo world!")
    }

    @Test
    @available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
    func testMutableReadableBytesSpanNotAtTheStart() {
        var bb = ByteBuffer(string: "Hello, world!")
        bb.moveReaderIndex(forwardBy: 5)
        #expect(bb.mutableReadableBytesSpan.byteCount == 8)
        let bytesEqual = bb.mutableReadableBytesSpan.elementsEqual(", world!".utf8)
        #expect(bytesEqual)

        var readableBytes = bb.mutableReadableBytesSpan
        readableBytes.storeBytes(of: UInt8(ascii: "o"), toByteOffset: 5, as: UInt8.self)

        #expect(String(buffer: bb) == ", worod!")
    }

    @Test
    @available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
    func testMutableReadableBytesSpanOfSlice() {
        let first = ByteBuffer(string: "Hello, world!")
        var bb = first.getSlice(at: 5, length: 5)!
        #expect(bb.mutableReadableBytesSpan.byteCount == 5)
        let bytesEqual = bb.mutableReadableBytesSpan.elementsEqual(", wor".utf8)
        #expect(bytesEqual)

        var readableBytes = bb.mutableReadableBytesSpan
        readableBytes.storeBytes(of: UInt8(ascii: "o"), toByteOffset: 4, as: UInt8.self)

        #expect(String(buffer: bb) == ", woo")
        #expect(String(buffer: first) == "Hello, world!")
    }

    @Test
    @available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
    func testEvenCreatingMutableSpanTriggersCoW() {
        let first = ByteBuffer(string: "Hello, world!")
        var second = first

        let firstBackingPtr = first.withVeryUnsafeBytes { $0 }.baseAddress
        let secondBackingPtr = second.withVeryUnsafeBytes { $0 }.baseAddress
        #expect(firstBackingPtr == secondBackingPtr)

        let readableBytes = second.mutableReadableBytesSpan
        _ = consume readableBytes
        let firstNewBackingPtr = first.withVeryUnsafeBytes { $0 }.baseAddress
        let secondNewBackingPtr = second.withVeryUnsafeBytes { $0 }.baseAddress
        #expect(firstNewBackingPtr != secondNewBackingPtr)
        #expect(firstBackingPtr == firstNewBackingPtr)
    }

    @Test
    @available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
    func testAppendingToEmptyBufferViaOutputSpan() {
        var bb = ByteBuffer()
        bb.writeWithOutputRawSpan(minimumWritableBytes: 15) { span in
            #expect(span.byteCount == 0)
            #expect(span.capacity >= 15)
            #expect(span.freeCapacity >= 15)
            var bytesEqual = span.initializedElementsEqual([])
            #expect(bytesEqual)

            span.append(contentsOf: "Hello, world!".utf8)

            #expect(span.byteCount == 13)
            #expect(span.capacity >= 2)
            #expect(span.freeCapacity >= 2)

            bytesEqual = span.initializedElementsEqual("Hello, world!".utf8)
            #expect(bytesEqual)
        }
        #expect(bb.readableBytes == 13)
        #expect(String(buffer: bb) == "Hello, world!")
    }

    @Test
    @available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
    func testAppendingToNonEmptyBufferViaOutputSpanDoesNotExposeInitialBytes() {
        var bb = ByteBuffer()
        bb.writeString("Hello")
        bb.writeWithOutputRawSpan(minimumWritableBytes: 8) { span in
            #expect(span.byteCount == 0)
            #expect(span.capacity >= 8)
            #expect(span.freeCapacity >= 8)
            var bytesEqual = span.initializedElementsEqual([])
            #expect(bytesEqual)

            span.append(contentsOf: ", world!".utf8)

            #expect(span.byteCount == 8)
            #expect(span.capacity >= 0)
            #expect(span.freeCapacity >= 0)
            bytesEqual = span.initializedElementsEqual(", world!".utf8)
            #expect(bytesEqual)
        }
        #expect(bb.readableBytes == 13)
        #expect(String(buffer: bb) == "Hello, world!")
    }

    @Test
    @available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
    func testAppendingToASliceViaOutputSpan() {
        let first = ByteBuffer(string: "Hello, world!")
        var bb = first.getSlice(at: 5, length: 5)!
        #expect(bb.mutableReadableBytesSpan.byteCount == 5)
        let bytesEqual = bb.mutableReadableBytesSpan.elementsEqual(", wor".utf8)
        #expect(bytesEqual)

        bb.writeWithOutputRawSpan(minimumWritableBytes: 5) { span in
            span.append(contentsOf: "olleh".utf8)
        }

        #expect(String(buffer: bb) == ", worolleh")
        #expect(String(buffer: first) == "Hello, world!")
    }

    @Test
    @available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
    func testEvenCreatingAnOutputSpanTriggersCoW() {
        let first = ByteBuffer(string: "Hello, world!")
        var second = first

        let firstBackingPtr = first.withVeryUnsafeBytes { $0 }.baseAddress
        let secondBackingPtr = second.withVeryUnsafeBytes { $0 }.baseAddress
        #expect(firstBackingPtr == secondBackingPtr)

        second.writeWithOutputRawSpan(minimumWritableBytes: 5) { _ in }
        let firstNewBackingPtr = first.withVeryUnsafeBytes { $0 }.baseAddress
        let secondNewBackingPtr = second.withVeryUnsafeBytes { $0 }.baseAddress
        #expect(firstNewBackingPtr != secondNewBackingPtr)
        #expect(firstBackingPtr == firstNewBackingPtr)
    }

    @Test
    @available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
    func testCanCreateEmptyBufferDirectly() {
        let bb = ByteBuffer(initialCapacity: 15) { span in
            #expect(span.byteCount == 0)
            #expect(span.capacity >= 15)
            #expect(span.freeCapacity >= 15)
            var bytesEqual = span.initializedElementsEqual([])
            #expect(bytesEqual)

            span.append(contentsOf: "Hello, world!".utf8)

            #expect(span.byteCount == 13)
            #expect(span.capacity >= 2)
            #expect(span.freeCapacity >= 2)
            bytesEqual = span.initializedElementsEqual("Hello, world!".utf8)
            #expect(bytesEqual)
        }
        #expect(bb.readableBytes == 13)
        #expect(String(buffer: bb) == "Hello, world!")
    }

    @Test
    @available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
    func testCanCreateEmptyBufferDirectlyFromAllocator() {
        let bb = ByteBufferAllocator().buffer(capacity: 15) { span in
            #expect(span.byteCount == 0)
            #expect(span.capacity >= 15)
            #expect(span.freeCapacity >= 15)
            var bytesEqual = span.initializedElementsEqual([])
            #expect(bytesEqual)

            span.append(contentsOf: "Hello, world!".utf8)

            #expect(span.byteCount == 13)
            #expect(span.capacity >= 2)
            #expect(span.freeCapacity >= 2)
            bytesEqual = span.initializedElementsEqual("Hello, world!".utf8)
            #expect(bytesEqual)
        }
        #expect(bb.readableBytes == 13)
        #expect(String(buffer: bb) == "Hello, world!")
    }

    @Test
    @available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
    func testReadableBytesUInt8SpanOfEmptyByteBuffer() {
        let bb = ByteBuffer()
        #expect(bb.readableBytesUInt8Span.count == 0)
    }

    @Test
    @available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
    func testReadableBytesUInt8SpanOfSimpleBuffer() {
        let bb = ByteBuffer(string: "Hello, world!")
        #expect(bb.readableBytesUInt8Span.count == 13)
        let bytesEqual = bb.readableBytesUInt8Span.elementsEqual("Hello, world!".utf8)
        #expect(bytesEqual)
    }

    @Test
    @available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
    func testReadableBytesUInt8SpanNotAtTheStart() {
        var bb = ByteBuffer(string: "Hello, world!")
        bb.moveReaderIndex(forwardBy: 5)
        #expect(bb.readableBytesUInt8Span.count == 8)
        let bytesEqual = bb.readableBytesUInt8Span.elementsEqual(", world!".utf8)
        #expect(bytesEqual)
    }

    @Test
    @available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
    func testReadableBytesUInt8SpanOfSlice() {
        let first = ByteBuffer(string: "Hello, world!")
        let bb = first.getSlice(at: 5, length: 5)!
        #expect(bb.readableBytesUInt8Span.count == 5)
        let bytesEqual = bb.readableBytesUInt8Span.elementsEqual(", wor".utf8)
        #expect(bytesEqual)
    }
}

@available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
extension RawSpan {
    func elementsEqual<Other: Collection>(_ other: Other) -> Bool where Other.Element == UInt8 {
        guard other.count == self.byteCount else { return false }

        var index = other.startIndex
        var offset = 0
        while index < other.endIndex {
            guard other[index] == self.unsafeLoadUnaligned(fromByteOffset: offset, as: UInt8.self) else {
                return false
            }
            other.formIndex(after: &index)
            offset &+= 1
        }

        return true
    }
}

@available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
extension Span<UInt8> {
    func elementsEqual<Other: Collection>(_ other: Other) -> Bool where Other.Element == UInt8 {
        guard other.count == self.count else { return false }
        guard var offset = self.indices.first else { return true }

        var index = other.startIndex
        while index < other.endIndex {
            guard other[index] == self[offset] else {
                return false
            }
            other.formIndex(after: &index)
            offset &+= 1
        }

        return true
    }
}

@available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
extension MutableRawSpan {
    func elementsEqual<Other: Collection>(_ other: Other) -> Bool where Other.Element == UInt8 {
        self.bytes.elementsEqual(other)
    }
}

@available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
extension OutputRawSpan {
    func initializedElementsEqual<Other: Collection>(_ other: Other) -> Bool where Other.Element == UInt8 {
        self.bytes.elementsEqual(other)
    }

    @_lifetime(self: copy self)
    mutating func append<Other: Collection>(contentsOf other: Other) where Other.Element == UInt8 {
        for element in other {
            self.append(element)
        }
    }
}
#endif
