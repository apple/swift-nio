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

extension ByteBuffer {
    
    fileprivate static func isThisTokenOneOf(_ constants: [ContiguousArray<UInt8>],
                                             pointer: inout UnsafePointer<UInt8>,
                                             length: inout Int,
                                             with whiteSpaces: [UInt8],
                                             separatedBy: UInt8) -> [Bool] {
        
        // Begin by all true
        var results = [Bool].init(repeating: true, count: constants.count)
        var characterIndexInConstants = 0
        var character = pointer.pointee & 0xdf
        var numberOfWhitespacesRead = 0
        var isLeading = true
        // Used pointer.pointee here because whitespace & 0xdf = 0, but here we want to check for null
        while (length > 0) && (character != separatedBy & 0xdf) && (pointer.pointee != 0) {
            defer {
                pointer = pointer.advanced(by: 1)
                character = pointer.pointee & 0xdf
                length -= 1
            }
            guard !whiteSpaces.contains(character) else {
                if !isLeading {
                    numberOfWhitespacesRead += 1
                }
                continue
            }
            isLeading = false
            // This is to handle the middle whiteSpaces, the whiteSpaces are counted
            // and if it reaches here (there is a new character), so it is in the middle
            // of a token
            characterIndexInConstants += numberOfWhitespacesRead
            constants.enumerated().forEach({ i in
                results[i.offset] = results[i.offset] &&
                    (characterIndexInConstants < i.element.count) && i.element[characterIndexInConstants] == character
            })
            // The leading and terminating whitespaces don't count
            // So we add it only if it is not a leading/terminating whitespace
            characterIndexInConstants += 1
        }
        // We are at most at a separator, so we want to skip it
        pointer = pointer.advanced(by: 1)
        return results.enumerated().map({
            $0.element && (characterIndexInConstants == constants[$0.offset].count - 1)
        })
    }
    
    func extractCaseInsensitiveCStrings(_ constants: [ContiguousArray<Int8>],
                                        startingWith start: Int,
                                        length: Int,
                                        with whiteSpaces: [Int8] = [" ".utf8CString[0], "\t".utf8CString[0]],
                                        separatedBy: UInt8 = UInt8(",".utf8CString[0])) -> [Bool] {
        var length = length
        
        var results = [Bool].init(repeating: false, count: constants.count)
        
        // Sanitize the ascii of constants array
        let constants = constants.map({ContiguousArray.init($0.map({UInt8($0) & 0xdf}))})
        
        return withVeryUnsafeBytes { pointer -> [Bool] in
            // This should never happens as we control when this is called. Adding an assert to ensure this.
            assert(start <= self.capacity - length)
            var address = pointer.baseAddress!.assumingMemoryBound(to: UInt8.self)
            while length > 0 {
                let newResults = ByteBuffer.isThisTokenOneOf(
                    constants, pointer: &address,
                    length: &length,
                    with: whiteSpaces.map({UInt8($0) & 0xdf}),
                    separatedBy: separatedBy)
                
                newResults.enumerated().forEach({results[$0.offset] = results[$0.offset] || newResults[$0.offset]})
            }
            
            return results
        }
    }
    
    func extractCaseInsensitiveConstantStrings(_ constants: [String],
                                               startingWith start: Int,
                                               length: Int) -> [Bool] {
        
        return extractCaseInsensitiveCStrings(constants.map({$0.utf8CString}),
                                              startingWith: start,
                                              length: length)
    }
    
    func extractCaseInsensitiveConstantStrings(_ constants: [String]) -> [Bool] {
        
        return extractCaseInsensitiveCStrings(constants.map({$0.utf8CString}),
                                              startingWith: self.readerIndex,
                                              length: self.readableBytes)
    }
}
