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

// This is a simplified vendored version from:
// https://github.com/fabianfett/swift-base64-kit

extension String {

  /// Base64 encode a collection of UInt8 to a string, without the use of Foundation.
  @inlinable
  init<Buffer: Collection>(base64Encoding bytes: Buffer)
    where Buffer.Element == UInt8
  {
    self = Base64.encode(bytes: bytes)
  }
}

@usableFromInline
internal struct Base64 {

  @inlinable
  static func encode<Buffer: Collection>(bytes: Buffer)
    -> String where Buffer.Element == UInt8
  {
    // In Base64, 3 bytes become 4 output characters, and we pad to the
    // nearest multiple of four.
    let newCapacity = ((bytes.count + 2) / 3) * 4
    let alphabet = Base64.encodeBase64
    
    // NOTE: Once SE-263 lands we should replace this implementation with one
    //       that makes use of the non copy initializer. For more information
    //       please see:
    //       https://github.com/apple/swift-evolution/blob/master/proposals/0263-string-uninitialized-initializer.md
    var outputBytes = [UInt8]()
    outputBytes.reserveCapacity(newCapacity)
    
    var input = bytes.makeIterator()
  
    while let firstByte = input.next() {
      let secondByte = input.next()
      let thirdByte = input.next()
      
      let firstChar  = Base64.encode(alphabet: alphabet, firstByte: firstByte)
      let secondChar = Base64.encode(alphabet: alphabet, firstByte: firstByte, secondByte: secondByte)
      let thirdChar  = Base64.encode(alphabet: alphabet, secondByte: secondByte, thirdByte: thirdByte)
      let forthChar  = Base64.encode(alphabet: alphabet, thirdByte: thirdByte)
      
      outputBytes.append(firstChar)
      outputBytes.append(secondChar)
      outputBytes.append(thirdChar)
      outputBytes.append(forthChar)
    }

    return String(decoding: outputBytes, as: Unicode.UTF8.self)
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
