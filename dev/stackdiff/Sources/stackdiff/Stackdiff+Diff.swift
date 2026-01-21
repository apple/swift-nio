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

import ArgumentParser
import Stacks

struct Diff: ParsableCommand {
    @OptionGroup
    var options: StackdiffOptions

    @Argument(help: "Path of first file to analyze")
    var fileA: String

    @Argument(help: "Path of second file to analyze")
    var fileB: String

    @Flag
    var showMergedStacks: Bool = false

    func run() throws {
        let a = try self.options.load(file: self.fileA)
        let b = try self.options.load(file: self.fileB)

        print("--- ONLY IN A (\(self.fileA))")
        print("")
        let aOnlyStacks = a.partialStacks.subtracting(b.partialStacks)
        let aOnlyAggregate = a.filter { aOnlyStacks.contains($0.key) }
        self.printSortedStacks(aOnlyAggregate)

        print("--- ONLY IN B (\(self.fileB))")
        print("")
        let bOnlyStacks = b.partialStacks.subtracting(a.partialStacks)
        let bOnlyAggregate = b.filter { bOnlyStacks.contains($0.key) }
        self.printSortedStacks(bOnlyAggregate)

        print("--- IN BOTH A AND B")
        print("")
        let inBoth = a.partialStacks.intersection(b.partialStacks)
        let diff = a.subtracting(b).filter {
            inBoth.contains($0.key) && $0.value.netAllocations != 0
        }
        self.printSortedStacks(diff)

        print("--- SUMMARY")
        print("")

        let allocsA = a.netAllocations
        let allocsB = b.netAllocations
        print("Allocs from all stacks in A:", allocsA)
        print("Allocs from all stacks in B:", allocsB)
        print("Difference:", allocsA - allocsB)
        print("")

        let uniqueAllocsA = aOnlyAggregate.netAllocations
        let uniqueAllocsB = bOnlyAggregate.netAllocations
        print("Allocs from stacks only in A:", uniqueAllocsA)
        print("Allocs from stacks only in B:", uniqueAllocsB)
        print("Difference:", uniqueAllocsA - uniqueAllocsB)
        print("")

        // Stacks in both A and B.
        let commonStacks = a.partialStacks.intersection(b.partialStacks)
        let commonAllocsA = a.filter { commonStacks.contains($0.key) }.netAllocations
        let commonAllocsB = b.filter { commonStacks.contains($0.key) }.netAllocations
        print("Allocs from common stacks in A:", commonAllocsA)
        print("Allocs from common stacks in B:", commonAllocsB)
        print("Difference:", commonAllocsA - commonAllocsB)
    }

    private func printSortedStacks(_ stacks: AggregateStacks) {
        let sorted = stacks.sorted(by: { $0.value.netAllocations > $1.value.netAllocations })
        if sorted.isEmpty {
            print("(none)\n")
        }
        for (stack, weightedSubstacks) in sorted {
            for line in StackFormatter.lines(
                forStack: stack,
                weightedSubstacks: weightedSubstacks,
                substackPrefix: "    "
            ) {
                print(line)
            }
            print("")
        }
    }
}
