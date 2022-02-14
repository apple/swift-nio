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

import XCTest
@testable import NIOCore
@testable import NIOPosix

class IPAddressTest: XCTestCase {
    
    func testDescriptionWorksIPv4() throws {
        let ipAddress = IPAddress(bytes: [
            1, 2, 3, 4
        ])
        print(ipAddress.description)
    }
    
    func testDescriptionWorksIPv6() throws {
        let ipAddress = IPAddress(bytes: [
            0, 1, 255, 3, 128, 5, 6, 54, 8, 9, 100, 11, 132, 13, 104, 15
        ])
        
        print(ipAddress.description)
    }
}
