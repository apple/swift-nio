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
import Foundation
import Stacks

@main
struct Stackdiff: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(subcommands: [Diff.self, Dump.self, Merge.self])
    }
}

struct StackdiffOptions: ParsableArguments {
    @Option(help: "The maximum stack depth used when comparing stacks.")
    var depth: Int?

    @Option(help: "The minimum number of allocations for a stack to be included.")
    var minAllocations: Int = 1000

    @Option(help: "The format of the input files.")
    var format: Format

    @Option(help: "If set, only stacks containing this string are included.")
    var filter: String?

    enum Format: String, ExpressibleByArgument, CaseIterable {
        case heaptrack
        case dtrace
        case bpftrace
    }
}

extension StackdiffOptions {
    func load(file: String) throws -> AggregateStacks {
        try AggregateStacks.load(
            contentsOf: file,
            format: self.format,
            depth: self.depth,
            minAllocations: self.minAllocations,
            filter: self.filter
        )
    }
}

extension AggregateStacks {
    static func load(
        contentsOf file: String,
        format: StackdiffOptions.Format,
        depth: Int?,
        minAllocations: Int,
        filter: String?
    ) throws -> Self {
        let lines = try readLinesOfFile(file)

        let stacks: [WeightedStack]
        switch format {
        case .heaptrack:
            stacks = HeaptrackParser.parse(lines: lines)
        case .dtrace:
            stacks = DTraceParser.parse(lines: lines)
        case .bpftrace:
            stacks = BPFTraceParser.parse(lines: lines)
        }

        // Combine equivalent stacks.
        var dedupedStacks: [Stack: Int] = [:]
        for stack in stacks {
            dedupedStacks[stack.stack, default: 0] += stack.allocations
        }

        var aggregate = AggregateStacks()

        for (stack, allocations) in dedupedStacks {
            let weightedStack = WeightedStack(stack: stack, allocations: allocations)
            let partialStack = weightedStack.prefix(depth ?? .max)
            aggregate.groupWeightedStack(weightedStack, by: partialStack)
        }

        // Remove light stacks
        for stack in aggregate.partialStacks {
            if aggregate.netAllocations(groupedBy: stack) < minAllocations {
                aggregate.removeWeightedStacks(groupedUnder: stack)
            }
        }

        // Remove stacks which don't contain the filter string.
        if let filter = filter {
            for stack in aggregate.partialStacks {
                if stack.lines.contains(where: { $0.contains(filter) }) {
                    continue
                } else {
                    aggregate.removeWeightedStacks(groupedUnder: stack)
                }
            }
        }

        return aggregate
    }
}

private func readLinesOfFile(_ path: String) throws -> [String] {
    let fileData = try Data(contentsOf: URL(filePath: path))
    let file = String(decoding: fileData, as: UTF8.self)
    let lines = Array(file.components(separatedBy: .newlines))
    return lines
}
