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

/// A collection of weighted stacks aggregated by their partial stacks.
///
/// Effectively a wrapper aound `[PartialStack: [WeightedStack]]` with a few helpers.
public struct AggregateStacks {
    private var storage: [PartialStack: [WeightedStack]]

    public init() {
        self.storage = [:]
    }

    /// The set of all partial stacks under which weighted stacks have been aggregated.
    public var partialStacks: Set<PartialStack> {
        Set(self.storage.keys)
    }

    /// The net allocations of all aggregated stacks.
    public var netAllocations: Int {
        self.storage.values.reduce(0) { partial, stackAllocs in
            partial + stackAllocs.netAllocations
        }
    }

    /// Adds a weighted stack under the given partial stack.
    public mutating func groupWeightedStack(_ stack: WeightedStack, by partial: PartialStack) {
        self.storage[partial, default: []].append(stack)
    }

    /// Regroups a set of stack from under one partial stack to another.
    public mutating func regroupStacks(from source: PartialStack, to destination: PartialStack) {
        guard let stacks = self.removeWeightedStacks(groupedUnder: source) else {
            return
        }

        self.storage[destination, default: []].append(contentsOf: stacks)
    }

    /// Removes all weighted stacks which are grouped under the given partial stack.
    @discardableResult
    public mutating func removeWeightedStacks(groupedUnder partial: PartialStack) -> [WeightedStack]? {
        self.storage.removeValue(forKey: partial)
    }

    /// Returns the net allocations of all stacks grouped under the given partial stack.
    public func netAllocations(groupedBy stack: PartialStack) -> Int {
        self.storage[stack]?.netAllocations ?? 0
    }

    /// Returns all weighted stacks grouped under the given partial stack.
    public func weightedStacks(groupedBy stack: PartialStack) -> [WeightedStack] {
        self.storage[stack, default: []]
    }

    /// Returns a new aggregate only containing pairs which return true for the given predidate.
    public func filter(
        isIncluded: ((key: PartialStack, value: [WeightedStack])) -> Bool
    ) -> AggregateStacks {
        var other = AggregateStacks()
        other.storage = self.storage.filter(isIncluded)
        return other
    }

    /// Removes all pairs which return true for the given predicate.
    public mutating func removeAll(
        where predicate: ((key: PartialStack, value: [WeightedStack])) -> Bool
    ) {
        for (stack, stackAllocs) in self.storage {
            if predicate((stack, stackAllocs)) {
                self.storage.removeValue(forKey: stack)
            }
        }
    }

    /// Returns a list of key-values pairs sorted by the given comparator.
    public func sorted(
        by comparator: (
            (key: PartialStack, value: [WeightedStack]),
            (key: PartialStack, value: [WeightedStack])
        ) -> Bool
    ) -> [(key: PartialStack, value: [WeightedStack])] {
        self.storage.sorted(by: comparator)
    }
}

extension AggregateStacks {
    public mutating func subtract(_ other: AggregateStacks) {
        for (partialStack, weightedStacks) in other.storage {
            for var weightedStack in weightedStacks {
                weightedStack.allocations = -weightedStack.allocations
                self.groupWeightedStack(weightedStack, by: partialStack)
            }
        }
    }

    public func subtracting(_ other: AggregateStacks) -> AggregateStacks {
        var copy = self
        copy.subtract(other)
        return copy
    }
}

extension [WeightedStack] {
    public var netAllocations: Int {
        self.reduce(0) { $0 + $1.allocations }
    }
}
