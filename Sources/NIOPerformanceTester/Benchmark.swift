//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Dispatch

protocol Benchmark: AnyObject {
    func setUp() throws
    func tearDown()
    func run() throws -> Int
}

func measureAndPrint<B: Benchmark>(desc: String, benchmark bench: B) throws {
    try bench.setUp()
    defer {
        bench.tearDown()
    }
    try measureAndPrint(desc: desc) {
        try bench.run()
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
protocol AsyncBenchmark: AnyObject, Sendable {
    func setUp() async throws
    func tearDown()
    func run() async throws -> Int
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
func measureAndPrint<B: AsyncBenchmark>(desc: String, benchmark bench: B) throws {
    let group = DispatchGroup()
    group.enter()
    Task {
        do {
            try await bench.setUp()
            defer {
                bench.tearDown()
            }
            try await measureAndPrint(desc: desc) {
                try await bench.run()
            }
        }
        group.leave()
    }

    group.wait()
}
