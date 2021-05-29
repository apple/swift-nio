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
    guard bytes.isEmpty == false else {
        return ""
    }
    // In Base64, 3 bytes become 4 output characters, and we pad to the
    // nearest multiple of four.
    let base64StringLength = ((bytes.count + 2) / 3) * 4
    let alphabet = Base64.encodeBase64
    
    // temporary buffer we use to store the output as zero terminated C string
    let outputBuffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: base64StringLength + 1)
    defer {
      outputBuffer.deallocate()
    }
    
    var input = bytes.makeIterator()
    var offset = 0
  
    while let firstByte = input.next() {
      let secondByte = input.next()
      let thirdByte = input.next()
      
      outputBuffer[offset] = Base64.encode(alphabet: alphabet, firstByte: firstByte)
      outputBuffer[offset + 1] = Base64.encode(alphabet: alphabet, firstByte: firstByte, secondByte: secondByte)
      outputBuffer[offset + 2] = Base64.encode(alphabet: alphabet, secondByte: secondByte, thirdByte: thirdByte)
      outputBuffer[offset + 3] = Base64.encode(alphabet: alphabet, thirdByte: thirdByte)
      offset += 4
    }
    
    // last char has to be a `0` in a zero terminated C string
    outputBuffer[offset] = 0

    // it is safe to force unwrap the baseAddress since we know that the output buffer is not empty
    return String(cString: outputBuffer.baseAddress!)
  }
  
  // MARK: Internal
  
  // The base64 unicode table.
  @usableFromInline
  static let encodeBase64: StaticString = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  
  static let encodePaddingCharacter: UInt8 = UInt8(ascii: "=")

  @usableFromInline
  static func encode(alphabet: StaticString, firstByte: UInt8) -> UInt8 {
    let index = firstByte >> 2
    return alphabet.withUTF8Buffer{ $0[Int(index)] }
  }

  @usableFromInline
  static func encode(alphabet: StaticString, firstByte: UInt8, secondByte: UInt8?) -> UInt8 {
    var index = (firstByte & 0b00000011) << 4
    if let secondByte = secondByte {
      index += (secondByte & 0b11110000) >> 4
    }
    return alphabet.withUTF8Buffer{ $0[Int(index)] }
  }

  @usableFromInline
  static func encode(alphabet: StaticString, secondByte: UInt8?, thirdByte: UInt8?) -> UInt8 {
    guard let secondByte = secondByte else {
      // No second byte means we are just emitting padding.
      return Base64.encodePaddingCharacter
    }
    var index = (secondByte & 0b00001111) << 2
    if let thirdByte = thirdByte {
      index += (thirdByte & 0b11000000) >> 6
    }
    return alphabet.withUTF8Buffer{ $0[Int(index)] }
  }

  @usableFromInline
  static func encode(alphabet: StaticString, thirdByte: UInt8?) -> UInt8 {
    guard let thirdByte = thirdByte else {
      // No third byte means just padding.
      return Base64.encodePaddingCharacter
    }
    let index = thirdByte & 0b00111111
    return alphabet.withUTF8Buffer{ $0[Int(index)] }
  }
}
