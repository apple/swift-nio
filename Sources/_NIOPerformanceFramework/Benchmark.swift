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

fileprivate let benchmarkRunCount = 10

/// Defines an interface for what an individual performance test should look like
public protocol _Benchmark: AnyObject {
    
    /// Used to identify the test, e.g. *nio_http1_1000_get_requests*
    var description: String { get }
    
    /// Perform any necessary setup such as state
    func setUp() throws
    
    /// E.g. clear state if needed
    func tearDown()
    
    /// Run the actual performance tests
    func run() throws -> Int
}

extension _Benchmark {

    fileprivate func measureAndPrint(limitSet: Set<String>, fn: () throws -> Int) rethrows {
        
        var warning: String = ""
        assert({
            print("======================================================")
            print("= YOU ARE RUNNING NIOPerformanceTester IN DEBUG MODE =")
            print("======================================================")
            warning = " <<< DEBUG MODE >>>"
            return true
        }())
        
        if limitSet.count == 0 || limitSet.contains(self.description) {
            print("measuring\(warning): \(self.description): ", terminator: "")
            let measurements = try measure(fn)
            print(measurements.reduce("") { $0 + "\($1), " })
        } else {
            print("skipping '\(self.description)', limit set = \(limitSet)")
        }
    }
    
    fileprivate func measure(_ fn: () throws -> Int) rethrows -> [TimeInterval] {
        func measureOne(_ fn: () throws -> Int) rethrows -> TimeInterval {
            let start = Date()
            _ = try fn()
            let end = Date()
            return end.timeIntervalSince(start)
        }

        _ = try measureOne(fn) /* pre-heat and throw away */
        var measurements = Array(repeating: 0.0, count: Config.benchmarkRunCount)
        for i in 0 ..< Config.benchmarkRunCount {
            measurements[i] = try measureOne(fn)
        }

        return measurements
    }
    
    fileprivate func runBenchmark(limitSet: Set<String>) throws {
        try self.setUp()
        defer {
            self.tearDown()
        }
        try measureAndPrint(limitSet: limitSet) {
            return try self.run()
        }
    }
    
}

struct Config {
    static let benchmarkRunCount = 10
}

/// Used to run a collection of benchmarks
public struct _PerformanceTester {
    
    public init() {
        
    }
 
    /// Runs a collection of benchmarks
    public func runBenchmarks(_ benchmarks: [_Benchmark]) throws {
        let limitSet = Set(CommandLine.arguments.dropFirst())
        try benchmarks.forEach { try $0.runBenchmark(limitSet: limitSet) }
    }
    
}
