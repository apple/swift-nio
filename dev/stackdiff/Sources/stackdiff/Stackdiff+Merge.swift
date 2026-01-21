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

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

struct Merge: ParsableCommand {
    @OptionGroup
    var options: StackdiffOptions

    @Argument(help: "Path of first file to analyze")
    var fileA: String

    @Argument(help: "Path of second file to analyze")
    var fileB: String

    @Flag(help: "Automatically merge stacks if they're similar enough.")
    var autoMerge = false

    @Option(help: "The minimum similarity score for stacks to be merged automatically (requires --auto-merge)")
    var autoMergeThreshold = 0.9

    @Flag(help: "Automatically skip stacks that aren't similar enough.")
    var autoSkip = false

    @Option(help: "The similarity below which a stack will be skipped automatically (requires --auto-skip)")
    var autoSkipThreshold = 0.55

    func run() throws {
        // The blank line in the message is intentional so that the formatting in the backtrace
        // is correct.
        assertionFailure(
            """

            *******************************************************************************
            **                                                                           **
            **       Debug mode is too slow! Please build and run in release mode.       **
            **                                                                           **
            *******************************************************************************
            """
        )

        let a = try self.options.load(file: self.fileA)
        let b = try self.options.load(file: self.fileB)

        var onlyA = a.partialStacks.subtracting(b.partialStacks)
        var onlyB = b.partialStacks.subtracting(a.partialStacks)

        // Merged contains stacks from A and B, with B recorded as negative allocations. Any
        // stacks grouped under the same partial stack should end up netting to zero. Any that
        // don't are changes in allocations between the two stacks.
        var merged = a.subtracting(b)

        print("Input A")
        print("- File:", self.fileA)
        print("- Allocations:", a.netAllocations)
        print("- Stacks:", a.partialStacks.count)
        print("- Stacks only in A:", onlyA.count)
        print("")
        print("Input B")
        print("- File:", self.fileB)
        print("- Allocations:", b.netAllocations)
        print("- Stacks:", b.partialStacks.count)
        print("- Stacks only in B:", onlyB.count)
        print("")
        print("Total stacks:", a.partialStacks.union(b.partialStacks).count)
        print("Allocation delta (A-B):", a.netAllocations - b.netAllocations)
        print("")
        print("About to start merging stacks, hit enter to continue ...")
        _ = readLine()

        if onlyA.count > 0 {
            self.mergeAllocations(from: onlyA, label: "A only", in: &merged) {
                onlyA.remove($0)
                onlyB.remove($1)
            }
        }

        if onlyB.count > 0 {
            self.mergeAllocations(from: onlyB, label: "B only", in: &merged) {
                onlyB.remove($0)
                onlyA.remove($1)
            }
        }

        ANSI.clearTerminal()

        // Remove empty stacks.
        print("Finished merging stacks, removing stacks with net zero allocations.")
        merged.removeAll { $0.value.netAllocations == 0 }
        print("Stacks remaining: \(merged.partialStacks.count)")
        print("Net allocations: \(merged.netAllocations)")
        print("")

        for (stack, weightedSubstacks) in merged.sorted(by: { $0.value.netAllocations > $1.value.netAllocations }) {
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

    private func mergeAllocations(
        from partialStacks: Set<PartialStack>,
        label: String,
        in aggregate: inout AggregateStacks,
        onMerge: (_ original: PartialStack, _ mergedWith: PartialStack) -> Void = { _, _ in }
    ) {
        // Make repeated runs deterministic.
        let sortedStacks = partialStacks.sorted { $0.lines.joined() > $1.lines.joined() }
        for (stackIndex, stack) in sortedStacks.enumerated() {
            // Only merge with other stacks where the net allocs isn't zero.
            let candidateStacks = aggregate.partialStacks.subtracting(partialStacks).filter { key in
                aggregate.netAllocations(groupedBy: key) != 0
            }

            // Order by decreasing similarity.
            let candidates = candidateStacks.map { candidate in
                let (_, similarity) = Similarity.levenshtein(stack, candidate)
                return (stack: candidate, similarity: similarity)
            }.sorted { lhs, rhs in
                lhs.similarity > rhs.similarity
            }

            for (candidateIndex, candidate) in candidates.enumerated() {
                let done = self.evaluateCandidate(
                    candidate.stack,
                    against: stack,
                    similarity: candidate.similarity,
                    label: label,
                    stackN: stackIndex + 1,
                    stackCount: sortedStacks.count,
                    candidateN: candidateIndex + 1,
                    candidateCount: candidates.count,
                    expandStacks: false,
                    aggregate: &aggregate,
                    onMerge: onMerge
                )

                if done {
                    break
                }
            }
        }
    }

    private func evaluateCandidate(
        _ candidate: PartialStack,
        against stack: PartialStack,
        similarity: Double,
        label: String,
        stackN: Int,
        stackCount: Int,
        candidateN: Int,
        candidateCount: Int,
        expandStacks: Bool,
        aggregate: inout AggregateStacks,
        onMerge: (PartialStack, PartialStack) -> Void
    ) -> Bool {
        ANSI.clearTerminal()
        print("Finding candidates for stack \(stackN) of \(stackCount) (S1) from \(label) ...")
        print("Looking at candidate stack \(candidateN) of \(candidateCount) (S2) ...")

        self.printCandidateSummary(
            stack: stack,
            candidate: candidate,
            similarity: similarity,
            aggregate: aggregate,
            expanded: expandStacks
        )

        if self.autoMerge && similarity >= self.autoMergeThreshold {
            aggregate.regroupStacks(from: stack, to: candidate)
            onMerge(stack, candidate)
            print("Outcome: auto-merged")
            return true
        }

        if self.autoSkip && similarity < self.autoSkipThreshold {
            print("Outcome: auto-skipped")
            return true
        }

        while true {
            switch self.getUserInput() {
            case .accept:
                // Remove the stacks from A and B.
                aggregate.regroupStacks(from: stack, to: candidate)
                onMerge(stack, candidate)
                print("Outcome: merged (by user)")
                return true

            case .reject:
                // Add a new line to make the output clearer.
                print("")
                print("Outcome: rejected (by user)")
                ANSI.clearTerminal()
                return false

            case .skip:
                print("Outcome: skipped (by user)")
                return true

            case .expand:
                return self.evaluateCandidate(
                    candidate,
                    against: stack,
                    similarity: similarity,
                    label: label,
                    stackN: stackN,
                    stackCount: stackCount,
                    candidateN: candidateN,
                    candidateCount: candidateCount,
                    expandStacks: true,
                    aggregate: &aggregate,
                    onMerge: onMerge
                )
            }
        }
    }

    private enum UserInput {
        case accept
        case reject
        case skip
        case expand

        init?(_ input: String, onNoInput: UserInput) {
            switch input.lowercased() {
            case "y", "yes":
                self = .accept
            case "n", "no":
                self = .reject
            case "s", "skip":
                self = .skip
            case "e", "expand":
                self = .expand
            case "":
                self = onNoInput
            default:
                return nil
            }
        }
    }

    private func getUserInput() -> UserInput {
        func underline(_ string: String) -> String {
            "\u{001B}[4m\(string)\u{001B}[0m"
        }

        let yes = "[" + underline("y") + "]es"
        let no = underline("n") + "o"
        let skip = underline("s") + "kip"
        let expand = underline("e") + "xpand"

        while true {
            print("")
            print("Accept (\(yes)/\(no)/\(skip)/\(expand))?: ", terminator: "")
            if let userInput = readLine(), let decision = UserInput(userInput, onNoInput: .accept) {
                return decision
            }
        }
    }

    private func printCandidateSummary(
        stack: PartialStack,
        candidate: PartialStack,
        similarity: Double,
        aggregate: AggregateStacks,
        expanded: Bool = false
    ) {
        print("")

        func makeAllocTable() -> [[String]] {
            var table: [[Any]] = []
            table.append(["", "A", "B", "Net"])

            let (sourcePos, sourceNeg) = aggregate.weightedStacks(
                groupedBy: stack
            ).reduce((0, 0)) { partial, allocStack in
                if allocStack.allocations > 0 {
                    return (partial.0 + allocStack.allocations, partial.1)
                } else {
                    return (partial.0, partial.1 + allocStack.allocations)
                }
            }
            var sourceNet: Int { sourcePos + sourceNeg }
            table.append(["S1", sourcePos, sourceNeg, sourceNet])

            let (candPos, candNeg) = aggregate.weightedStacks(
                groupedBy: candidate
            ).reduce((0, 0)) { partial, allocStack in
                if allocStack.allocations > 0 {
                    return (partial.0 + allocStack.allocations, partial.1)
                } else {
                    return (partial.0, partial.1 + allocStack.allocations)
                }
            }
            var candNet: Int { candPos + candNeg }
            table.append(["S2", candPos, candNeg, candNet])
            table.append(["Total", sourcePos + candPos, sourceNeg + candNeg, sourceNet + candNet])

            return table.map { row in
                row.map { String(describing: $0) }
            }
        }

        print("Allocations:")
        self.printFormattedTable(makeAllocTable())
        print("")

        // Highlight weak/strong matches.
        let similarityText: String
        if similarity < self.autoSkipThreshold {
            similarityText = ANSI.red(String(describing: similarity))
        } else if similarity >= self.autoMergeThreshold {
            similarityText = ANSI.green(String(describing: similarity))
        } else {
            similarityText = ANSI.yellow(String(describing: similarity))
        }

        print("Stack similarity:", similarityText)
        print("")

        let (dropFirst, dropLast): (Int, Int)
        if expanded {
            (dropFirst, dropLast) = (0, 0)
        } else {
            (dropFirst, dropLast) = self.lengthOfCommonPrefixAndSuffix(stack.lines, candidate.lines)
        }

        // Grab the window size to clip long lines.
        var windowSize = winsize()
        _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &windowSize)

        for line in StackFormatter.lines(
            forStack: stack,
            prefixedWith: "S1| ",
            dropFirst: dropFirst,
            dropLast: dropLast,
            maxWidth: Int(windowSize.ws_col)
        ) {
            print(line)
        }

        print("")

        for line in StackFormatter.lines(
            forStack: candidate,
            prefixedWith: "S2| ",
            dropFirst: dropFirst,
            dropLast: dropLast,
            maxWidth: Int(windowSize.ws_col)
        ) {
            print(line)
        }
    }

    private func printFormattedTable(_ table: [[String]]) {
        precondition(!table.isEmpty)
        precondition(table.allSatisfy { $0.count == table[0].count })

        var columnWidths = Array(repeating: 0, count: table[0].count)
        for row in table {
            for colIndex in row.indices {
                let width = row[colIndex].count
                if width > columnWidths[colIndex] {
                    columnWidths[colIndex] = width
                }
            }
        }

        for row in table {
            var line = ""
            var iterator = zip(row, columnWidths).makeIterator()
            var current = iterator.next()
            while let (cell, width) = current {
                line += String(repeating: " ", count: width - cell.count + 1)  // Add an extra space
                line += cell
                line += " "

                current = iterator.next()
                if current != nil {
                    line += "|"
                }
            }
            print(line)
        }
    }

    private func lengthOfCommonPrefix(_ a: some Sequence<String>, _ b: some Sequence<String>) -> Int {
        var length = 0

        for (x, y) in zip(a, b) {
            if x == y {
                length += 1
            } else {
                break
            }
        }

        return length
    }

    private func lengthOfCommonSuffix(_ a: some Sequence<String>, _ b: some Sequence<String>) -> Int {
        self.lengthOfCommonPrefix(a.reversed(), b.reversed())
    }

    private func lengthOfCommonPrefixAndSuffix(_ a: [String], _ b: [String]) -> (Int, Int) {
        if a == b {
            return (a.count, 0)
        }

        let prefixLength = self.lengthOfCommonPrefix(a, b)

        if prefixLength == a.count || prefixLength == b.count {
            return (prefixLength, 0)
        }

        let suffixLength = self.lengthOfCommonSuffix(a, b)

        return (prefixLength, suffixLength)
    }
}

extension Similarity {
    static func levenshtein(
        _ a: PartialStack,
        _ b: PartialStack
    ) -> (distance: Int, similarity: Double) {
        Self.levenshtein(a.lines.joined(), b.lines.joined())
    }
}

enum ANSI {
    static func clearTerminal() {
        print("\u{1B}[H\u{1B}[2J", terminator: "")
    }

    static func red(_ text: String) -> String {
        "\u{001B}[31m\(text)\u{001B}[0m"
    }

    static func green(_ text: String) -> String {
        "\u{001B}[32m\(text)\u{001B}[0m"
    }

    static func yellow(_ text: String) -> String {
        "\u{001B}[33m\(text)\u{001B}[0m"
    }
}
