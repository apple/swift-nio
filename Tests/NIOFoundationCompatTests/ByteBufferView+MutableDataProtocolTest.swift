//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019-2021 Apple Inc. and the SwiftNIO project authors
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

class ByteBufferViewDataProtocolTests: XCTestCase {

    func testResetBytes() {
        var view = ByteBufferView()
        view.resetBytes(in: view.indices)
        XCTAssertTrue(view.elementsEqual([]))

        view.replaceSubrange(view.indices, with: [1, 2, 3, 4, 5])

        view.resetBytes(in: 0..<2)
        XCTAssertTrue(view.elementsEqual([0, 0, 3, 4, 5]))

        view.resetBytes(in: 2...4)
        XCTAssertTrue(view.elementsEqual([0, 0, 0, 0, 0]))
    }

    func testCreateDataFromBuffer() {
        let testString = "some sample bytes"
        let buffer = ByteBuffer(ByteBufferView(testString.utf8))
        let data = Data(buffer: buffer)
        XCTAssertEqual(Array(data), Array(testString.utf8))
    }
}
