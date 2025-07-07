//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

public protocol StackParser {
    static func parse(lines: some Sequence<String>) throws -> [WeightedStack]
}

public protocol StackProtocol {
    var lines: [String] { get }
}

extension StackProtocol {
    /// Returns a stack with at most `maxLength` lines from the start of the current stack.
    public func prefix(_ maxLength: Int) -> PartialStack {
        PartialStack(self.lines.prefix(max(0, maxLength)))
    }

    /// Returns a stack with at most `maxLength` lines from the end of the current stack.
    public func suffix(_ maxLength: Int) -> PartialStack {
        PartialStack(self.lines.suffix(max(0, maxLength)))
    }
}

/// The lines of a full stack trace.
public struct Stack: Hashable, StackProtocol {
    public var lines: [String]

    public init(_ lines: [String]) {
        self.lines = lines
    }

    public init(_ weighted: WeightedStack) {
        self = weighted.stack
    }
}

/// The lines of a possibly incomplete stack trace.
public struct PartialStack: Hashable, StackProtocol {
    public var lines: [String]

    public init(_ lines: some Sequence<String>) {
        self.lines = Array(lines)
    }
}

/// A stack with an associated number of allocations
public struct WeightedStack: Hashable, StackProtocol {
    public var stack: Stack
    public var allocations: Int

    public var lines: [String] {
        self.stack.lines
    }

    public init(lines: [String], allocations: Int) {
        self.init(stack: Stack(lines), allocations: allocations)
    }

    public init(stack: Stack, allocations: Int) {
        self.stack = stack
        self.allocations = allocations
    }
}
