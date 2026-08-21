//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import XCTest

@testable import NIOHTTP1

private enum DummyError: Error {
    case err
}

class ByteBufferUtilsTest: XCTestCase {

    func testComparators() {
        let someByteBuffer: ByteBuffer = ByteBuffer(string: "fiRSt")
        XCTAssert(
            someByteBuffer.readableBytesView.compareCaseInsensitiveASCIIBytes(
                to: "first".utf8
            )
        )
        XCTAssert(
            someByteBuffer.readableBytesView.compareCaseInsensitiveASCIIBytes(
                to: "fiRSt".utf8
            )
        )
        XCTAssert(
            someByteBuffer.readableBytesView.compareCaseInsensitiveASCIIBytes(
                to: "fIrst".utf8
            )
        )
        XCTAssertFalse(
            someByteBuffer.readableBytesView.compareCaseInsensitiveASCIIBytes(
                to: "fIrt".utf8
            )
        )
        XCTAssertFalse(
            someByteBuffer.readableBytesView.compareCaseInsensitiveASCIIBytes(
                to: "firsta".utf8
            )
        )
        XCTAssertFalse(
            someByteBuffer.readableBytesView.compareCaseInsensitiveASCIIBytes(
                to: "afirst".utf8
            )
        )
        XCTAssertFalse(
            someByteBuffer.readableBytesView.compareCaseInsensitiveASCIIBytes(
                to: "eiRSt".utf8
            )
        )
        XCTAssertFalse(
            someByteBuffer.readableBytesView.compareCaseInsensitiveASCIIBytes(
                to: "fIrso".utf8
            )
        )
        XCTAssertFalse(
            someByteBuffer.readableBytesView.compareCaseInsensitiveASCIIBytes(
                to: "firot".utf8
            )
        )
    }

    func testComparatorsDoNotFoldNonAlphaPunctuationThatSharesTheCaseBit() {
        // These punctuation pairs only differ from one another in bit 0x20 (the
        // same bit that separates an ASCII lowercase letter from its uppercase
        // form), so a naive `byte & 0xdf` case-fold incorrectly treats them as
        // equal. All of these bytes are legal `tchar` characters in HTTP header
        // field names (RFC 7230 §3.2.6), so they must never compare as equal to
        // one another.
        let collidingPairs: [(String, String)] = [
            ("^", "~"),
            ("[", "{"),
            ("]", "}"),
            ("\\", "|"),
            ("@", "`"),
        ]

        for (lhs, rhs) in collidingPairs {
            let buffer = ByteBuffer(string: "X-Foo\(lhs)Bar")
            XCTAssertFalse(
                buffer.readableBytesView.compareCaseInsensitiveASCIIBytes(to: "X-Foo\(rhs)Bar".utf8),
                "'\(lhs)' (0x\(String(lhs.utf8.first!, radix: 16))) incorrectly compared equal to " +
                    "'\(rhs)' (0x\(String(rhs.utf8.first!, radix: 16)))"
            )
            // The identical byte must still compare equal to itself.
            XCTAssertTrue(
                buffer.readableBytesView.compareCaseInsensitiveASCIIBytes(to: "X-Foo\(lhs)Bar".utf8)
            )
        }

        // Sanity check: real ASCII letters must still fold correctly.
        XCTAssertTrue(
            ByteBuffer(string: "X-Foo^Bar").readableBytesView.compareCaseInsensitiveASCIIBytes(
                to: "x-foo^bar".utf8
            )
        )
    }

    private func byteBufferView(string: String) -> ByteBufferView {
        let byteBufferAllocator = ByteBufferAllocator()
        var buffer = byteBufferAllocator.buffer(capacity: string.lengthOfBytes(using: .utf8))
        buffer.writeString(string)
        return buffer.readableBytesView
    }

    func testTrimming() {
        XCTAssertEqual(
            byteBufferView(string: "   first").trimSpaces().map({ CChar($0) }),
            byteBufferView(string: "first").map({ CChar($0) })
        )
        XCTAssertEqual(
            byteBufferView(string: "   first  ").trimSpaces().map({ CChar($0) }),
            byteBufferView(string: "first").map({ CChar($0) })
        )
        XCTAssertEqual(
            byteBufferView(string: "first  ").trimSpaces().map({ CChar($0) }),
            byteBufferView(string: "first").map({ CChar($0) })
        )
        XCTAssertEqual(
            byteBufferView(string: "first").trimSpaces().map({ CChar($0) }),
            byteBufferView(string: "first").map({ CChar($0) })
        )
        XCTAssertEqual(
            byteBufferView(string: " \t\t  fi  rst").trimSpaces().map({ CChar($0) }),
            byteBufferView(string: "fi  rst").map({ CChar($0) })
        )
        XCTAssertEqual(
            byteBufferView(string: "   firs  t \t ").trimSpaces().map({ CChar($0) }),
            byteBufferView(string: "firs  t").map({ CChar($0) })
        )
        XCTAssertEqual(
            byteBufferView(string: "f\t  irst  ").trimSpaces().map({ CChar($0) }),
            byteBufferView(string: "f\t  irst").map({ CChar($0) })
        )
        XCTAssertEqual(
            byteBufferView(string: "f i  rs  t").trimSpaces().map({ CChar($0) }),
            byteBufferView(string: "f i  rs  t").map({ CChar($0) })
        )
        XCTAssertEqual(
            byteBufferView(string: "   \t \t ").trimSpaces().map({ CChar($0) }),
            byteBufferView(string: "").map({ CChar($0) })
        )
    }

}
