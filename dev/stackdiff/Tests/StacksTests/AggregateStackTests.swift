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

import Stacks
import Testing

struct AggregateStackTests {
    @Test
    func netAllocations() {
        var aggregate = AggregateStacks()
        #expect(aggregate.netAllocations == 0)

        aggregate.groupWeightedStack(
            WeightedStack(lines: ["a"], allocations: 100),
            by: PartialStack(["a"])
        )

        #expect(aggregate.netAllocations == 100)

        aggregate.groupWeightedStack(
            WeightedStack(lines: ["a"], allocations: -10),
            by: PartialStack(["a"])
        )

        #expect(aggregate.netAllocations == 90)
    }

    @Test
    func groupWeightedStack() {
        var aggregate = AggregateStacks()

        let partial = PartialStack(["a"])
        let weighted = ["a", "b", "c"].map { line in
            WeightedStack(lines: ["a"] + [line], allocations: 10)
        }

        for weightedStack in weighted {
            aggregate.groupWeightedStack(weightedStack, by: partial)
        }

        aggregate.groupWeightedStack(
            WeightedStack(lines: [], allocations: 0),
            by: PartialStack(["b"])
        )

        #expect(aggregate.netAllocations(groupedBy: partial) == 30)

        let grouped = aggregate.weightedStacks(groupedBy: partial)
        #expect(grouped == weighted)
    }

    @Test
    func removeWeightedStacks() {
        var aggregate = AggregateStacks()
        let partial = PartialStack(["a"])

        // Nothing to remove.
        #expect(aggregate.removeWeightedStacks(groupedUnder: partial) == nil)

        // Add then remove.
        let weighted = WeightedStack(lines: ["a"], allocations: 100)
        aggregate.groupWeightedStack(weighted, by: partial)
        #expect(aggregate.removeWeightedStacks(groupedUnder: partial) == [weighted])
    }

    @Test
    func filter() {
        var aggregate = AggregateStacks()

        let partialA = PartialStack(["a"])
        let partialB = PartialStack(["b"])
        aggregate.groupWeightedStack(WeightedStack(lines: ["a"], allocations: 10), by: partialA)
        aggregate.groupWeightedStack(WeightedStack(lines: ["b"], allocations: -10), by: partialB)
        #expect(aggregate.netAllocations == 0)

        let filtered = aggregate.filter { $0.key.lines == ["a"] }
        #expect(filtered.netAllocations == 10)
    }

    @Test
    func removeAll() {
        var aggregate = AggregateStacks()

        let partialA = PartialStack(["a"])
        let partialB = PartialStack(["b"])
        aggregate.groupWeightedStack(WeightedStack(lines: ["a"], allocations: 10), by: partialA)
        aggregate.groupWeightedStack(WeightedStack(lines: ["b"], allocations: -10), by: partialB)
        #expect(aggregate.netAllocations == 0)

        aggregate.removeAll { $0.key.lines == ["a"] }
        #expect(aggregate.netAllocations == -10)
    }

    @Test
    func subtract() {
        let weighted = WeightedStack(lines: [], allocations: 10)

        var aggregateA = AggregateStacks()
        aggregateA.groupWeightedStack(weighted, by: PartialStack(["m"]))
        aggregateA.groupWeightedStack(weighted, by: PartialStack(["n"]))

        var aggregateB = AggregateStacks()
        aggregateB.groupWeightedStack(weighted, by: PartialStack(["m"]))
        aggregateB.groupWeightedStack(weighted, by: PartialStack(["o"]))

        let diff = aggregateA.subtracting(aggregateB)

        // m=10 in A and B
        #expect(diff.netAllocations(groupedBy: PartialStack(["m"])) == 0)
        #expect(diff.weightedStacks(groupedBy: PartialStack(["m"])).count == 2)

        // n=10 in A and not present in B
        #expect(diff.netAllocations(groupedBy: PartialStack(["n"])) == 10)
        #expect(diff.weightedStacks(groupedBy: PartialStack(["n"])).count == 1)

        // o=10 in B and not present in A
        #expect(diff.netAllocations(groupedBy: PartialStack(["o"])) == -10)
        #expect(diff.weightedStacks(groupedBy: PartialStack(["o"])).count == 1)
    }
}
