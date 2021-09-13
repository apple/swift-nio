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
import NIOHTTP1

func run(identifier: String) {
    measure(identifier: identifier) {
        let headers: HTTPHeaders = ["key": "no,trimming"]
        var count = 0
        for _ in 0..<100_000 {
            count &+= headers[canonicalForm: "key"].count
        }
        return count
    }

    measure(identifier: identifier + "_trimming_whitespace") {
        let headers: HTTPHeaders = ["key": "         some   ,   trimming     "]
        var count = 0
        for _ in 0..<100_000 {
            count &+= headers[canonicalForm: "key"].count
        }
        return count
    }

    measure(identifier: identifier + "_trimming_whitespace_from_short_string") {
        // first components has length > 15 with whitespace and <= 15 without.
        let headers: HTTPHeaders = ["key": "   smallString   ,whenStripped"]
        var count = 0
        for _ in 0..<100_000 {
            count &+= headers[canonicalForm: "key"].count
        }
        return count
    }

    measure(identifier: identifier + "_trimming_whitespace_from_long_string") {
        let headers: HTTPHeaders = ["key": " moreThan15CharactersWithAndWithoutWhitespace ,anotherValue"]
        var count = 0
        for _ in 0..<100_000 {
            count &+= headers[canonicalForm: "key"].count
        }
        return count
    }
}
