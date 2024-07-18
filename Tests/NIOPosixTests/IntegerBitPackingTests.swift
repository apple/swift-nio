//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest

@testable import NIOPosix

final class IntegerBitPackingTests: XCTestCase {
    func testAllUInt8PairsRoundtrip() {
        for i in UInt16.min...UInt16.max {
            let unpacked = IntegerBitPacking.unpackUInt8UInt8(i)
            XCTAssertEqual(i, IntegerBitPacking.packUInt8UInt8(unpacked.0, unpacked.1))
        }
    }

    func testExtremesWorkForUInt32UInt16UInt8() {
        XCTAssert(
            (.max, .max, .max)
                == IntegerBitPacking.unpackUInt32UInt16UInt8(
                    IntegerBitPacking.packUInt32UInt16UInt8(
                        .max,
                        .max,
                        .max
                    )
                )
        )

        XCTAssert(
            (0, 0, 0) == IntegerBitPacking.unpackUInt32UInt16UInt8(IntegerBitPacking.packUInt32UInt16UInt8(0, 0, 0))
        )

        XCTAssert(
            (UInt32(1) << 31 | 1, UInt16(1) << 15 | 1, UInt8(1) << 7 | 1)
                == IntegerBitPacking.unpackUInt32UInt16UInt8(
                    IntegerBitPacking.packUInt32UInt16UInt8(
                        UInt32(1) << 31 | 1,
                        UInt16(1) << 15 | 1,
                        UInt8(1) << 7 | 1
                    )
                )
        )

        let randomUInt32 = UInt32.random(in: .min ... .max)
        let randomUInt16 = UInt16.random(in: .min ... .max)
        let randomUInt8 = UInt8.random(in: .min ... .max)
        XCTAssert(
            (randomUInt32, randomUInt16, randomUInt8)
                == IntegerBitPacking.unpackUInt32UInt16UInt8(
                    IntegerBitPacking.packUInt32UInt16UInt8(randomUInt32, randomUInt16, randomUInt8)
                ),
            "\((randomUInt32, randomUInt16, randomUInt8)) didn't roundtrip"
        )
    }

    func testExtremesWorkForUInt16UInt8() {
        XCTAssert((.max, .max) == IntegerBitPacking.unpackUInt16UInt8(IntegerBitPacking.packUInt16UInt8(.max, .max)))

        XCTAssert((0, 0) == IntegerBitPacking.unpackUInt16UInt8(IntegerBitPacking.packUInt16UInt8(0, 0)))

        XCTAssert(
            (UInt16(1) << 15 | 1, UInt8(1) << 7 | 1)
                == IntegerBitPacking.unpackUInt16UInt8(
                    IntegerBitPacking.packUInt16UInt8(
                        UInt16(1) << 15 | 1,
                        UInt8(1) << 7 | 1
                    )
                )
        )
    }

    func testExtremesWorkForUInt32CInt() {
        XCTAssert((.max, .max) == IntegerBitPacking.unpackUInt32CInt(IntegerBitPacking.packUInt32CInt(.max, .max)))

        XCTAssert((0, 0) == IntegerBitPacking.unpackUInt32CInt(IntegerBitPacking.packUInt32CInt(0, 0)))

        XCTAssert((.min, -1) == IntegerBitPacking.unpackUInt32CInt(IntegerBitPacking.packUInt32CInt(.min, -1)))

        XCTAssert((.min, .min) == IntegerBitPacking.unpackUInt32CInt(IntegerBitPacking.packUInt32CInt(.min, .min)))

        XCTAssert(
            (UInt32(1) << 31 | 1, CInt(1) << 31)
                == IntegerBitPacking.unpackUInt32CInt(
                    IntegerBitPacking.packUInt32CInt(
                        UInt32(1) << 31 | 1,
                        CInt(1) << 31
                    )
                )
        )

        let randomUInt32 = UInt32.random(in: .min ... .max)
        let randomCInt = CInt.random(in: .min ... .max)
        XCTAssert(
            (randomUInt32, randomCInt)
                == IntegerBitPacking.unpackUInt32CInt(IntegerBitPacking.packUInt32CInt(randomUInt32, randomCInt)),
            "\((randomUInt32, randomCInt)) didn't roundtrip"
        )
    }

}
