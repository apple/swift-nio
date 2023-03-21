//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOPerformanceTester
import NIOHTTP1
import Benchmark

let benchmarks = {
    Benchmark.defaultConfiguration = .init(metrics:[.wallClock, .mallocCountTotal, .throughput],
                                           warmupIterations: 0,
                                           maxDuration: .seconds(1),
                                           maxIterations: Int.max)

    Benchmark("write_http_headers") { benchmark in
        var headers: [(String, String)] = []
        for i in 1..<10 {
            headers.append(("\(i)", "\(i)"))
        }

        var val = 0
        for _ in benchmark.scaledIterations {
            let headers = HTTPHeaders(headers)
            val += headers.underestimatedCount
        }
        blackHole(val)
    }

    Benchmark("http_headers_canonical_form") { benchmark in
        let headers: HTTPHeaders = ["key": "no,trimming"]
        var count = 0
        for _ in benchmark.scaledIterations {
            count &+= headers[canonicalForm: "key"].count
        }
        blackHole(count)
    }

    Benchmark("http_headers_canonical_form_trimming_whitespace") { benchmark in
        let headers: HTTPHeaders = ["key": "         some   ,   trimming     "]
        var count = 0
        for _ in benchmark.scaledIterations {
            count &+= headers[canonicalForm: "key"].count
        }
        blackHole(count)
    }

    Benchmark("http_headers_canonical_form_trimming_whitespace_from_short_string") { benchmark in
        let headers: HTTPHeaders = ["key": "   smallString   ,whenStripped"]
        var count = 0
        for _ in benchmark.scaledIterations {
            count &+= headers[canonicalForm: "key"].count
        }
        blackHole(count)
    }

    Benchmark("http_headers_canonical_form_trimming_whitespace_from_long_string") { benchmark in
        let headers: HTTPHeaders = ["key": " moreThan15CharactersWithAndWithoutWhitespace ,anotherValue"]
        var count = 0
        for _ in benchmark.scaledIterations {
            count &+= headers[canonicalForm: "key"].count
        }
        blackHole(count)
    }
}
