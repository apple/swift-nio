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

struct Dump: ParsableCommand {
    @Argument
    var file: String

    @OptionGroup
    var options: StackdiffOptions

    func run() throws {
        let aggregate = try self.options.load(file: self.file)
        let allocs = aggregate.netAllocations

        // Sort by allocations.
        let sortedStacks = aggregate.sorted {
            $0.value.netAllocations > $1.value.netAllocations
        }

        for (stack, weightedSubstacks) in sortedStacks {
            for line in StackFormatter.lines(
                forStack: stack,
                weightedSubstacks: weightedSubstacks,
                substackPrefix: "    "
            ) {
                print(line)
            }
            print("")
        }

        print("TOTAL ALLOCATIONS: \(allocs)")
    }
}
