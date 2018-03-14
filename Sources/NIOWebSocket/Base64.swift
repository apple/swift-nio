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

// The base64 unicode table.
private let base64Table: [UnicodeScalar] = [
    "A", "B", "C", "D", "E", "F", "G", "H",
    "I", "J", "K", "L", "M", "N", "O", "P",
    "Q", "R", "S", "T", "U", "V", "W", "X",
    "Y", "Z", "a", "b", "c", "d", "e", "f",
    "g", "h", "i", "j", "k", "l", "m", "n",
    "o", "p", "q", "r", "s", "t", "u", "v",
    "w", "x", "y", "z", "0", "1", "2", "3",
    "4", "5", "6", "7", "8", "9", "+", "/",
]

internal extension String {
    /// Base64 encode an array of UInt8 to a string, without the use of Foundation.
    ///
    /// This function performs the world's most naive Base64 encoding: no attempts to use a larger
    /// lookup table or anything intelligent like that, just shifts and masks. This works fine, for
    /// now: the purpose of this encoding is to avoid round-tripping through Data, and the perf gain
    /// from avoiding that is more than enough to outweigh the silliness of this code.
    init(base64Encoding array: Array<UInt8>) {
        // In Base64, 3 bytes become 4 output characters, and we pad to the nearest multiple
        // of four.
        var outputString = String()
        outputString.reserveCapacity(((array.count + 2) / 3) * 4)

        var bytes = array.makeIterator()
        while let firstByte = bytes.next() {
            let secondByte = bytes.next()
            let thirdByte = bytes.next()
            outputString.unicodeScalars.append(String.encode(firstByte: firstByte))
            outputString.unicodeScalars.append(String.encode(firstByte: firstByte, secondByte: secondByte))
            outputString.unicodeScalars.append(String.encode(secondByte: secondByte, thirdByte: thirdByte))
            outputString.unicodeScalars.append(String.encode(thirdByte: thirdByte))
        }

        self = outputString
    }

    private static func encode(firstByte: UInt8) -> UnicodeScalar {
        let index = firstByte >> 2
        return base64Table[Int(index)]
    }

    private static func encode(firstByte: UInt8, secondByte: UInt8?) -> UnicodeScalar {
        var index = (firstByte & 0b00000011) << 4
        if let secondByte = secondByte {
            index += (secondByte & 0b11110000) >> 4
        }
        return base64Table[Int(index)]
    }

    private static func encode(secondByte: UInt8?, thirdByte: UInt8?) -> UnicodeScalar {
        guard let secondByte = secondByte else {
            // No second byte means we are just emitting padding.
            return "="
        }
        var index = (secondByte & 0b00001111) << 2
        if let thirdByte = thirdByte {
            index += (thirdByte & 0b11000000) >> 6
        }
        return base64Table[Int(index)]
    }

    private static func encode(thirdByte: UInt8?) -> UnicodeScalar {
        guard let thirdByte = thirdByte else {
            // No third byte means just padding.
            return "="
        }
        let index = thirdByte & 0b00111111
        return base64Table[Int(index)]
    }
}
