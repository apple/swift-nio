//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// This is a simplified vendored version from:
// https://github.com/fabianfett/swift-base64-kit

public extension String {

    /// Base64 encode a collection of UInt8 to a string, without the use of Foundation.
    @inlinable
    init<Buffer: Collection>(base64Encoding bytes: Buffer) where Buffer.Element == UInt8 {
        self = Base64.encode(bytes: bytes)
    }

    @inlinable
    func base64Decoded() throws -> [UInt8] {
        return try Base64.decode(string: self)
    }
}

public enum Base64Error: Error {
    case invalidLength
    case invalidCharacter
}

@usableFromInline
internal struct Base64 {

    @inlinable
    static func encode<Buffer: Collection>(bytes: Buffer) -> String where Buffer.Element == UInt8 {
        guard !bytes.isEmpty else {
            return ""
        }

        // In Base64, 3 bytes become 4 output characters, and we pad to the
        // nearest multiple of four.
        let base64StringLength = ((bytes.count + 2) / 3) * 4
        let alphabet = Base64.encodeBase64

        return String(customUnsafeUninitializedCapacity: base64StringLength) { backingStorage in
            var input = bytes.makeIterator()
            var offset = 0
            while let firstByte = input.next() {
                let secondByte = input.next()
                let thirdByte = input.next()

                backingStorage[offset] = Base64.encode(alphabet: alphabet, firstByte: firstByte)
                backingStorage[offset + 1] = Base64.encode(alphabet: alphabet, firstByte: firstByte, secondByte: secondByte)
                backingStorage[offset + 2] = Base64.encode(alphabet: alphabet, secondByte: secondByte, thirdByte: thirdByte)
                backingStorage[offset + 3] = Base64.encode(alphabet: alphabet, thirdByte: thirdByte)
                offset += 4
            }
            return offset
        }
    }

    @inlinable
    static func decode(string: String) throws -> [UInt8] {
        guard string.count % 4 == 0 else {
            throw Base64Error.invalidLength
        }

        let bytes = string.utf8.map { $0 }
        var decoded = [UInt8]()

        // Go over the encoded string in groups of 4 characters,
        // and build groups of 3 bytes from them.
        for i in stride(from: 0, to: bytes.count, by: 4) {
            guard let byte0Index = Base64.encodeBase64.firstIndex(of: bytes[i]),
                  let byte1Index = Base64.encodeBase64.firstIndex(of: bytes[i+1]) else {
                throw Base64Error.invalidCharacter
            }

            let byte0 = (UInt8(byte0Index) << 2 | UInt8(byte1Index) >> 4)
            decoded.append(byte0)

            // Check if the 3rd char is not a padding character, and decode the 2nd byte
            if bytes[i+2] != Base64.encodePaddingCharacter {
                guard let byte2Index = Base64.encodeBase64.firstIndex(of: bytes[i+2]) else {
                    throw Base64Error.invalidCharacter
                }

                let second = (UInt8(byte1Index) << 4 | UInt8(byte2Index) >> 2)
                decoded.append(second)
            }

            // Check if the 4th character is not a padding, and decode the 3rd byte
            if bytes[i+3] != Base64.encodePaddingCharacter {
                guard let byte3Index = Base64.encodeBase64.firstIndex(of: bytes[i+3]),
                      let byte2Index = Base64.encodeBase64.firstIndex(of: bytes[i+2]) else {
                    throw Base64Error.invalidCharacter
                }
                let third = (UInt8(byte2Index) << 6 | UInt8(byte3Index))
                decoded.append(third)
            }
        }
        return decoded
    }


    // MARK: Internal

    // The base64 unicode table.
    @usableFromInline
    static let encodeBase64: [UInt8] = [
        UInt8(ascii: "A"), UInt8(ascii: "B"), UInt8(ascii: "C"), UInt8(ascii: "D"),
        UInt8(ascii: "E"), UInt8(ascii: "F"), UInt8(ascii: "G"), UInt8(ascii: "H"),
        UInt8(ascii: "I"), UInt8(ascii: "J"), UInt8(ascii: "K"), UInt8(ascii: "L"),
        UInt8(ascii: "M"), UInt8(ascii: "N"), UInt8(ascii: "O"), UInt8(ascii: "P"),
        UInt8(ascii: "Q"), UInt8(ascii: "R"), UInt8(ascii: "S"), UInt8(ascii: "T"),
        UInt8(ascii: "U"), UInt8(ascii: "V"), UInt8(ascii: "W"), UInt8(ascii: "X"),
        UInt8(ascii: "Y"), UInt8(ascii: "Z"), UInt8(ascii: "a"), UInt8(ascii: "b"),
        UInt8(ascii: "c"), UInt8(ascii: "d"), UInt8(ascii: "e"), UInt8(ascii: "f"),
        UInt8(ascii: "g"), UInt8(ascii: "h"), UInt8(ascii: "i"), UInt8(ascii: "j"),
        UInt8(ascii: "k"), UInt8(ascii: "l"), UInt8(ascii: "m"), UInt8(ascii: "n"),
        UInt8(ascii: "o"), UInt8(ascii: "p"), UInt8(ascii: "q"), UInt8(ascii: "r"),
        UInt8(ascii: "s"), UInt8(ascii: "t"), UInt8(ascii: "u"), UInt8(ascii: "v"),
        UInt8(ascii: "w"), UInt8(ascii: "x"), UInt8(ascii: "y"), UInt8(ascii: "z"),
        UInt8(ascii: "0"), UInt8(ascii: "1"), UInt8(ascii: "2"), UInt8(ascii: "3"),
        UInt8(ascii: "4"), UInt8(ascii: "5"), UInt8(ascii: "6"), UInt8(ascii: "7"),
        UInt8(ascii: "8"), UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "/"),
    ]

    @usableFromInline
    static let encodePaddingCharacter: UInt8 = UInt8(ascii: "=")

    @usableFromInline
    static func encode(alphabet: [UInt8], firstByte: UInt8) -> UInt8 {
        let index = firstByte >> 2
        return alphabet[Int(index)]
    }

    @usableFromInline
    static func encode(alphabet: [UInt8], firstByte: UInt8, secondByte: UInt8?) -> UInt8 {
        var index = (firstByte & 0b00000011) << 4
        if let secondByte = secondByte {
            index += (secondByte & 0b11110000) >> 4
        }
        return alphabet[Int(index)]
    }

    @usableFromInline
    static func encode(alphabet: [UInt8], secondByte: UInt8?, thirdByte: UInt8?) -> UInt8 {
        guard let secondByte = secondByte else {
            // No second byte means we are just emitting padding.
            return Base64.encodePaddingCharacter
        }
        var index = (secondByte & 0b00001111) << 2
        if let thirdByte = thirdByte {
            index += (thirdByte & 0b11000000) >> 6
        }
        return alphabet[Int(index)]
    }

    @usableFromInline
    static func encode(alphabet: [UInt8], thirdByte: UInt8?) -> UInt8 {
        guard let thirdByte = thirdByte else {
            // No third byte means just padding.
            return Base64.encodePaddingCharacter
        }
        let index = thirdByte & 0b00111111
        return alphabet[Int(index)]
    }
}

extension String {
    /// This is a backport of a proposed String initializer that will allow writing directly into an uninitialized String's backing memory.
    ///
    /// As this API does not exist prior to 5.3 on Linux, or on older Apple platforms, we fake it out with a pointer and accept the extra copy.
    @inlinable
    init(backportUnsafeUninitializedCapacity capacity: Int,
         initializingUTF8With initializer: (_ buffer: UnsafeMutableBufferPointer<UInt8>) throws -> Int) rethrows {

        // The buffer will store zero terminated C string
        let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: capacity + 1)
        defer {
            buffer.deallocate()
        }

        let initializedCount = try initializer(buffer)
        precondition(initializedCount <= capacity, "Overran buffer in initializer!")

        // add zero termination
        buffer[initializedCount] = 0

        self = String(cString: buffer.baseAddress!)
    }
}

// Frustratingly, Swift 5.3 shipped before the macOS 11 SDK did, so we cannot gate the availability of
// this declaration on having the 5.3 compiler. This has caused a number of build issues. While updating
// to newer Xcodes does work, we can save ourselves some hassle and just wait until 5.4 to get this
// enhancement on Apple platforms.
extension String {

    @inlinable
    init(customUnsafeUninitializedCapacity capacity: Int,
         initializingUTF8With initializer: (_ buffer: UnsafeMutableBufferPointer<UInt8>) throws -> Int) rethrows {
        if #available(macOS 11.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *) {
            try self.init(unsafeUninitializedCapacity: capacity, initializingUTF8With: initializer)
        } else {
            try self.init(backportUnsafeUninitializedCapacity: capacity, initializingUTF8With: initializer)
        }
    }
}
