//
// Copyright (c) 2022 Ordo One AB.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//

import NIOPerformanceTester
import NIOHTTP1

import BenchmarkSupport
@main
extension BenchmarkRunner {}


// swiftlint disable: attributes
@_dynamicReplacement(for: registerBenchmarks)
func benchmarks() {
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
