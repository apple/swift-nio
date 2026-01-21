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

import Foundation
import NIOCore
import NIOFoundationCompat
import XCTest

class JSONSerializationByteBufferTest: XCTestCase {

    func testSerializationRoundTrip() {

        let array = ["String1", "String2", "String3"]
        let dictionary = ["key1": "val1", "key2": "val2", "key3": "val3"]

        var dataArray = Data()
        var dataDictionary = Data()

        XCTAssertTrue(JSONSerialization.isValidJSONObject(array), "Array object cannot be converted to JSON")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(dictionary), "Dictionary object cannot be converted to JSON")

        XCTAssertNoThrow(dataArray = try JSONSerialization.data(withJSONObject: array, options: .prettyPrinted))
        XCTAssertNoThrow(
            dataDictionary = try JSONSerialization.data(withJSONObject: dictionary, options: .prettyPrinted)
        )

        let arrayByteBuffer = ByteBuffer(data: dataArray)
        let dictByteBuffer = ByteBuffer(data: dataDictionary)

        var foundationArray: [String] = []
        var foundationDict: [String: String] = [:]

        // Mutable containers comparison.
        XCTAssertNoThrow(
            foundationArray =
                try JSONSerialization.jsonObject(with: arrayByteBuffer, options: .mutableContainers) as! [String]
        )
        XCTAssertEqual(foundationArray, array)

        XCTAssertNoThrow(
            foundationDict =
                try JSONSerialization.jsonObject(with: dictByteBuffer, options: .mutableContainers) as! [String: String]
        )
        XCTAssertEqual(foundationDict, dictionary)

        // Mutable leaves comparison.
        XCTAssertNoThrow(
            foundationArray =
                try JSONSerialization.jsonObject(with: arrayByteBuffer, options: .mutableLeaves) as! [String]
        )
        XCTAssertEqual(foundationArray, array)

        XCTAssertNoThrow(
            foundationDict =
                try JSONSerialization.jsonObject(with: dictByteBuffer, options: .mutableLeaves) as! [String: String]
        )
        XCTAssertEqual(foundationDict, dictionary)
    }
}
