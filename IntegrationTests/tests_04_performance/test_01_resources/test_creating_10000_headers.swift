//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOHTTP1

func run(identifier: String) {
    measure(identifier: identifier) {
        var count = 0

        for _ in 0..<10_000 {
            let baseHeaders: [(String, String)] = [("Host", "example.com"), ("Content-Length", "4")]
            count += HTTPHeaders(baseHeaders).count
        }

        return count
    }
}
