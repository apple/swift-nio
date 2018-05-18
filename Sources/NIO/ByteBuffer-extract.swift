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
    
    fileprivate static func compareReadingToCaseInsensitiveCString(_ constant: ContiguousArray<UInt8>,
                                                                   pointer: inout UnsafePointer<UInt8>,
                                                                   length: inout Int) -> Bool {
        assert(constant.last == 0)
        
        // We assume that the constant variable is coming from UTF8String, which gives a null terminated
        let constant = constant.dropLast()
        
        if length < constant.count { return false }

        for char in constant {
            if (pointer.pointee & 0xdf) != char { return false }
            print(pointer.pointee)
            pointer = pointer.advanced(by: 1)
            length -= 1
        }
        return true
        
    }

    fileprivate static func compareReadingToCaseSensitiveCString(_ constant: ContiguousArray<UInt8>,
                                                                 pointer: inout UnsafePointer<UInt8>,
                                                                 length: inout Int) -> Bool {
        
        // In case sensitive, it is safe to do the null comparison, there is no & 0xdf, so null != ' '
        if length < constant.count { return false }
        
        for char in constant {
            if (pointer.pointee) != char { return false }
            pointer = pointer.advanced(by: 1)
            length -= 1
        }
        return true
        
    }

    fileprivate static func trimLeadingWhitespacesByPointer(pointer: inout UnsafePointer<UInt8>,
                                                            length: inout Int,
                                                            with whiteSpaces: [UInt8]) {
        while length > 0 && pointer.pointee != 0 && whiteSpaces.contains(pointer.pointee) {
            pointer = pointer.advanced(by: 1)
            length -= 1
        }
    }

    fileprivate func trimLeadingWhitespaces(start: Int,
                                            length: Int,
                                            with whiteSpaces: [UInt8]) -> Int {
        var length = length
        var ret = 0
        return withVeryUnsafeBytes { pointer in
            assert(start <= self.capacity - length)
            var address = pointer.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: start)
            while length > 0 && address.pointee != 0 && whiteSpaces.contains(address.pointee) {
                address = address.advanced(by: 1)
                length -= 1
                ret += 1
            }
            return ret
        }
    }
    
    public func tokens(separatedBy: UInt8 = UInt8(",".utf8CString[0]),
                       startingWith start: Int,
                       length: Int) -> [(start: Int, length: Int)] {
        
        var length = length
        
        var results: [(start: Int, length: Int)] = []
        
        var beginning = 0
        var tokenLength = 0
        
        return withVeryUnsafeBytes { pointer -> [(start: Int, length: Int)] in
            // This should never happens as we control when this is called. Adding an assert to ensure this.
            assert(start <= self.capacity - length)
            var address = pointer.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: start)
            while length > 0 && address.pointee != 0 {
                if address.pointee == separatedBy {
                    results.append((start: beginning, length: tokenLength))
                    // The new beginning is after the last one then adding the separator length (= 1)
                    beginning = beginning + tokenLength + 1
                    // Reset tokenLength, we still didn't read it, we use -1 here because it will
                    // soon be incremented
                    tokenLength = -1
                }
                length -= 1
                address = address.advanced(by: 1)
                tokenLength += 1
            }
            results.append((start: beginning, length: tokenLength))

            return results
        }

    }
    
    /// A buffer based extractor for case insensitive strings
    ///
    /// - Parameters:
    ///   - constants:   The string constants, in the form of arrays of UInt8, those are constants
    ///                  so you can generate them one time, cache them, and use them here.
    ///   - start:       The start of the buffer to parse
    ///   - length:      Length of what to parse in the buffer
    ///   - whiteSpaces: An array of bytes to be used as whitespaces, defaults to space and tab
    ///   - separatedBy: A byte which represents the separator.
    /// - Returns:
    ///   A boolean array, each represents the state of the words respectively,
    ///
    ///   **Example:**
    ///
    ///   When the array of strings is `["Foo", "Bar"]`, and the return is `[true, false]`.
    ///   Then `"Foo"` **exists**, while `"Bar"` **no**
    public func extractCaseInsensitiveCStrings(_ constants: [ContiguousArray<UInt8>],
                                               startingWith start: Int,
                                               length: Int,
                                               with whiteSpaces: [UInt8] = [" ".utf8CString[0], "\t".utf8CString[0]].map({UInt8($0)}),
                                               separatedBy: UInt8 = UInt8(",".utf8CString[0])) -> [Bool] {
        let tokenPositions = tokens(separatedBy: separatedBy, startingWith: start, length: length)
        var results = [Bool].init(repeating: false, count: constants.count)
        return withVeryUnsafeBytes { pointer -> [Bool] in
            let address = pointer.baseAddress!.assumingMemoryBound(to: UInt8.self)
            tokenPositions.forEach({ token in
                var address = address + token.start
                var len = token.length
                ByteBuffer.trimLeadingWhitespacesByPointer(pointer: &address, length: &len, with: whiteSpaces)
                constants.enumerated().forEach({ constant in
                    var address = address
                    var len = len
                    if ByteBuffer.compareReadingToCaseInsensitiveCString(constant.element, pointer: &address, length: &len) {
                        // Check that all is left is only white spaces
                        ByteBuffer.trimLeadingWhitespacesByPointer(pointer: &address, length: &len, with: whiteSpaces)
                        // When trying to trim, if the remaining length = 0, all left is white spaces
                        if len == 0 {
                            results[constant.offset] = true
                        }
                    }
                })
            })
            
            return results
        }
    }
    
    /// A convenience function that uses strings to be passed to
    /// `extractCaseInsensitiveCStrings(_:starting:length:whiteSpaces:separatedBy:)`
    /// It doesn't cache the conversion from Strings, so it may be expensive if compilation is
    /// not optimized
    ///
    /// - Parameters:
    ///   - constants: String constants to get the state of
    ///   - start: Starting index of parsing
    ///   - length: Length of thing to be parsed
    /// - Returns: The array, in the same form returned by
    /// `extractCaseInsensitiveCStrings(_:starting:length:whiteSpaces:separatedBy:)`
    public func extractCaseInsensitiveConstantStrings(_ constants: [String],
                                                      startingWith start: Int,
                                                      length: Int) -> [Bool] {
        
        return extractCaseInsensitiveCStrings(
            constants.map({ContiguousArray($0.utf8CString.map({UInt8($0) & 0xdf}))}),
            startingWith: start,
            length: length)
    }
    
    /// A convenience function that uses strings to be passed to
    /// `extractCaseInsensitiveCStrings(_:starting:length:whiteSpaces:separatedBy:)`
    /// It doesn't cache the conversion from Strings, so it may be expensive if compilation is
    /// not optimized.
    ///
    /// This function also calculates start and end, from the reading index and readable bytes.
    ///
    /// - Parameters:
    ///   - constants: String constants to get the state of
    /// - Returns: The array, in the same form returned by
    /// `extractCaseInsensitiveCStrings(_:starting:length:whiteSpaces:separatedBy:)`
    public func extractCaseInsensitiveConstantStrings(_ constants: [String]) -> [Bool] {
        
        return extractCaseInsensitiveCStrings(
            constants.map({ContiguousArray($0.utf8CString.map({UInt8($0) & 0xdf}))}),
            startingWith: self.readerIndex,
            length: self.readableBytes)
    }
}
