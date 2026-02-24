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

enum StackFormatter {
    static func lines<Stack: StackProtocol>(
        forStack stack: Stack,
        prefixedWith linePrefix: String = "",
        dropFirst: Int = 0,
        dropLast: Int = 0,
        maxWidth: Int? = nil
    ) -> [String] {
        var lines = [String]()
        lines.reserveCapacity(stack.lines.count - dropFirst - dropLast)

        if dropFirst > 0 {
            lines.append(linePrefix + "...skipping \(dropFirst) common lines...")
        }

        for line in stack.lines.dropFirst(dropFirst).dropLast(dropLast) {
            lines.append(linePrefix + line)
        }

        if dropLast > 0 {
            lines.append(linePrefix + "...skipping \(dropLast) common lines...")
        }

        if let maxWidth = maxWidth {
            return lines.map { $0.truncated(to: maxWidth) }
        } else {
            return lines
        }
    }

    static func lines(
        forStack stack: some StackProtocol,
        weightedSubstacks: [WeightedStack],
        prefixedWith linePrefix: String = "",
        substackPrefix: String = "",
        maxWidth: Int? = nil
    ) -> [String] {
        var lines = [String]()

        // If theres' only a single substack, compress it into the main stack.
        if weightedSubstacks.count == 1, let substack = weightedSubstacks.first {
            lines.append("\(linePrefix)ALLOCATIONS: \(substack.allocations)")
            lines.append(
                contentsOf: Self.lines(
                    forStack: substack.stack,
                    prefixedWith: linePrefix,
                    maxWidth: maxWidth
                )
            )
            return lines
        }

        let totalAllocs = weightedSubstacks.reduce(0) { $0 + $1.allocations }
        lines.append("\(linePrefix)ALLOCATIONS: \(totalAllocs)")
        lines.append(
            contentsOf: Self.lines(
                forStack: stack,
                prefixedWith: linePrefix,
                maxWidth: maxWidth
            )
        )
        for substack in weightedSubstacks {
            // Add a divider between substacks.
            lines.append("")
            lines.append("\(linePrefix)\(substackPrefix)ALLOCATIONS: \(substack.allocations)")
            // Treat the substack as a regular stack.
            let substackLines = Self.lines(
                forStack: substack.suffix(substack.lines.count - stack.lines.count),
                prefixedWith: linePrefix + substackPrefix,
                maxWidth: maxWidth
            )
            lines.append(contentsOf: substackLines)
        }

        return lines
    }
}

extension String {
    func truncated(to maxLength: Int, continuation: String = "...") -> String {
        let length = self.count

        if length <= maxLength {
            return self
        }

        let toRemove = (length - maxLength) + continuation.count

        var copy = self
        copy.removeLast(toRemove)
        copy.append(contentsOf: continuation)

        return copy
    }
}
