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

public protocol Benchmark: AnyObject {
    func setUp() throws
    func tearDown()
    func run() throws -> Int
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol AsyncBenchmark: AnyObject, Sendable {
    func setUp() async throws
    func tearDown()
    func run() async throws -> Int
}
