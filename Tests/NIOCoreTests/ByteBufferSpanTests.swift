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

import XCTest

import NIOCore

#if compiler(>=6.2)
@available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
final class ByteBufferSpanTests: XCTestCase {
    func testReadableBytesSpanOfEmptyByteBuffer() {
        let bb = ByteBuffer()
        XCTAssertEqual(bb.readableBytesSpan.byteCount, 0)
    }

    func testReadableBytesSpanOfSimpleBuffer() {
        let bb = ByteBuffer(string: "Hello, world!")
        XCTAssertEqual(bb.readableBytesSpan.byteCount, 13)
        XCTAssertTrue(bb.readableBytesSpan.elementsEqual("Hello, world!".utf8))
    }

    func testReadableBytesSpanNotAtTheStart() {
        var bb = ByteBuffer(string: "Hello, world!")
        bb.moveReaderIndex(forwardBy: 5)
        XCTAssertEqual(bb.readableBytesSpan.byteCount, 8)
        XCTAssertTrue(bb.readableBytesSpan.elementsEqual(", world!".utf8))
    }

    func testReadableBytesSpanOfSlice() {
        let first = ByteBuffer(string: "Hello, world!")
        let bb = first.getSlice(at: 5, length: 5)!
        XCTAssertEqual(bb.readableBytesSpan.byteCount, 5)
        XCTAssertTrue(bb.readableBytesSpan.elementsEqual(", wor".utf8))
    }

    func testMutableReadableBytesSpanOfEmptyByteBuffer() {
        var bb = ByteBuffer()
        XCTAssertEqual(bb.mutableReadableBytesSpan.byteCount, 0)
    }

    func testMutableReadableBytesSpanOfSimpleBuffer() {
        var bb = ByteBuffer(string: "Hello, world!")
        XCTAssertEqual(bb.mutableReadableBytesSpan.byteCount, 13)
        XCTAssertTrue(bb.mutableReadableBytesSpan.elementsEqual("Hello, world!".utf8))

        var readableBytes = bb.mutableReadableBytesSpan
        readableBytes.storeBytes(of: UInt8(ascii: "o"), toByteOffset: 5, as: UInt8.self)

        XCTAssertEqual(String(buffer: bb), "Helloo world!")
    }

    func testMutableReadableBytesSpanNotAtTheStart() {
        var bb = ByteBuffer(string: "Hello, world!")
        bb.moveReaderIndex(forwardBy: 5)
        XCTAssertEqual(bb.mutableReadableBytesSpan.byteCount, 8)
        XCTAssertTrue(bb.mutableReadableBytesSpan.elementsEqual(", world!".utf8))

        var readableBytes = bb.mutableReadableBytesSpan
        readableBytes.storeBytes(of: UInt8(ascii: "o"), toByteOffset: 5, as: UInt8.self)

        XCTAssertEqual(String(buffer: bb), ", worod!")
    }

    func testMutableReadableBytesSpanOfSlice() {
        let first = ByteBuffer(string: "Hello, world!")
        var bb = first.getSlice(at: 5, length: 5)!
        XCTAssertEqual(bb.mutableReadableBytesSpan.byteCount, 5)
        XCTAssertTrue(bb.mutableReadableBytesSpan.elementsEqual(", wor".utf8))

        var readableBytes = bb.mutableReadableBytesSpan
        readableBytes.storeBytes(of: UInt8(ascii: "o"), toByteOffset: 4, as: UInt8.self)

        XCTAssertEqual(String(buffer: bb), ", woo")
        XCTAssertEqual(String(buffer: first), "Hello, world!")
    }

    func testEvenCreatingMutableSpanTriggersCoW() {
        let first = ByteBuffer(string: "Hello, world!")
        var second = first

        let firstBackingPtr = first.withVeryUnsafeBytes { $0 }.baseAddress
        let secondBackingPtr = second.withVeryUnsafeBytes { $0 }.baseAddress
        XCTAssertEqual(firstBackingPtr, secondBackingPtr)

        let readableBytes = second.mutableReadableBytesSpan
        _ = consume readableBytes
        let firstNewBackingPtr = first.withVeryUnsafeBytes { $0 }.baseAddress
        let secondNewBackingPtr = second.withVeryUnsafeBytes { $0 }.baseAddress
        XCTAssertNotEqual(firstNewBackingPtr, secondNewBackingPtr)
        XCTAssertEqual(firstBackingPtr, firstNewBackingPtr)
    }

    func testAppendingToEmptyBufferViaOutputSpan() {
        var bb = ByteBuffer()
        bb.writeWithOutputRawSpan(minimumWritableBytes: 15) { span in
            XCTAssertEqual(span.byteCount, 0)
            XCTAssertGreaterThanOrEqual(span.capacity, 15)
            XCTAssertGreaterThanOrEqual(span.freeCapacity, 15)
            XCTAssertTrue(span.initializedElementsEqual([]))

            span.append(contentsOf: "Hello, world!".utf8)

            XCTAssertEqual(span.byteCount, 13)
            XCTAssertGreaterThanOrEqual(span.capacity, 2)
            XCTAssertGreaterThanOrEqual(span.freeCapacity, 2)
            XCTAssertTrue(span.initializedElementsEqual("Hello, world!".utf8))
        }
        XCTAssertEqual(bb.readableBytes, 13)
        XCTAssertEqual(String(buffer: bb), "Hello, world!")
    }

    func testAppendingToNonEmptyBufferViaOutputSpanDoesNotExposeInitialBytes() {
        var bb = ByteBuffer()
        bb.writeString("Hello")
        bb.writeWithOutputRawSpan(minimumWritableBytes: 8) { span in
            XCTAssertEqual(span.byteCount, 0)
            XCTAssertGreaterThanOrEqual(span.capacity, 8)
            XCTAssertGreaterThanOrEqual(span.freeCapacity, 8)
            XCTAssertTrue(span.initializedElementsEqual([]))

            span.append(contentsOf: ", world!".utf8)

            XCTAssertEqual(span.byteCount, 8)
            XCTAssertGreaterThanOrEqual(span.capacity, 0)
            XCTAssertGreaterThanOrEqual(span.freeCapacity, 0)
            XCTAssertTrue(span.initializedElementsEqual(", world!".utf8))
        }
        XCTAssertEqual(bb.readableBytes, 13)
        XCTAssertEqual(String(buffer: bb), "Hello, world!")
    }

    func testAppendingToASliceViaOutputSpan() {
        let first = ByteBuffer(string: "Hello, world!")
        var bb = first.getSlice(at: 5, length: 5)!
        XCTAssertEqual(bb.mutableReadableBytesSpan.byteCount, 5)
        XCTAssertTrue(bb.mutableReadableBytesSpan.elementsEqual(", wor".utf8))

        bb.writeWithOutputRawSpan(minimumWritableBytes: 5) { span in
            span.append(contentsOf: "olleh".utf8)
        }

        XCTAssertEqual(String(buffer: bb), ", worolleh")
        XCTAssertEqual(String(buffer: first), "Hello, world!")
    }

    func testEvenCreatingAnOutputSpanTriggersCoW() {
        let first = ByteBuffer(string: "Hello, world!")
        var second = first

        let firstBackingPtr = first.withVeryUnsafeBytes { $0 }.baseAddress
        let secondBackingPtr = second.withVeryUnsafeBytes { $0 }.baseAddress
        XCTAssertEqual(firstBackingPtr, secondBackingPtr)

        second.writeWithOutputRawSpan(minimumWritableBytes: 5) { _ in}
        let firstNewBackingPtr = first.withVeryUnsafeBytes { $0 }.baseAddress
        let secondNewBackingPtr = second.withVeryUnsafeBytes { $0 }.baseAddress
        XCTAssertNotEqual(firstNewBackingPtr, secondNewBackingPtr)
        XCTAssertEqual(firstBackingPtr, firstNewBackingPtr)
    }

    func testCanCreateEmptyBufferDirectly() {
        let bb = ByteBuffer(initialCapacity: 15) { span in
            XCTAssertEqual(span.byteCount, 0)
            XCTAssertGreaterThanOrEqual(span.capacity, 15)
            XCTAssertGreaterThanOrEqual(span.freeCapacity, 15)
            XCTAssertTrue(span.initializedElementsEqual([]))

            span.append(contentsOf: "Hello, world!".utf8)

            XCTAssertEqual(span.byteCount, 13)
            XCTAssertGreaterThanOrEqual(span.capacity, 2)
            XCTAssertGreaterThanOrEqual(span.freeCapacity, 2)
            XCTAssertTrue(span.initializedElementsEqual("Hello, world!".utf8))
        }
        XCTAssertEqual(bb.readableBytes, 13)
        XCTAssertEqual(String(buffer: bb), "Hello, world!")
    }

    func testCanCreateEmptyBufferDirectlyFromAllocator() {
        let bb = ByteBufferAllocator().buffer(capacity: 15) { span in
            XCTAssertEqual(span.byteCount, 0)
            XCTAssertGreaterThanOrEqual(span.capacity, 15)
            XCTAssertGreaterThanOrEqual(span.freeCapacity, 15)
            XCTAssertTrue(span.initializedElementsEqual([]))

            span.append(contentsOf: "Hello, world!".utf8)

            XCTAssertEqual(span.byteCount, 13)
            XCTAssertGreaterThanOrEqual(span.capacity, 2)
            XCTAssertGreaterThanOrEqual(span.freeCapacity, 2)
            XCTAssertTrue(span.initializedElementsEqual("Hello, world!".utf8))
        }
        XCTAssertEqual(bb.readableBytes, 13)
        XCTAssertEqual(String(buffer: bb), "Hello, world!")
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
