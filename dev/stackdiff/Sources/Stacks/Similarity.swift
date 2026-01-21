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

public enum Similarity {
    /// Returns the Levenshtein distance between two strings and their similarity score.
    ///
    /// See also: https://en.wikipedia.org/wiki/Levenshtein_distance
    ///
    /// The score is normalized to 0...1, with 1 indicting an exact match. Scores are calculated
    /// as `1 - levenshtein(a, b) / max(length(a), length(b))`.
    public static func levenshtein(_ a: String, _ b: String) -> (distance: Int, similarity: Double) {
        Self.levenshtein(Array(a.utf8), Array(b.utf8))
    }

    private static func levenshtein(
        _ a: [UInt8],
        _ b: [UInt8]
    ) -> (distance: Int, similarity: Double) {
        if a.isEmpty, b.isEmpty {
            // Perfect match.
            return (0, 1.0)
        } else if a.isEmpty {
            // A is empty, B isn't. Distance is length of B.
            return (b.count, 0.0)
        } else if b.isEmpty {
            // B is empty, A isn't. Distance is length of A.
            return (a.count, 0.0)
        }

        var distance = Array(0...b.count)

        for rowIndex in 1...a.count {
            var previous = distance[0]
            distance[0] = rowIndex

            for colIndex in 1...b.count {
                let temp = distance[colIndex]

                if a[rowIndex - 1] == b[colIndex - 1] {
                    distance[colIndex] = previous
                } else {
                    distance[colIndex] = 1 + min(distance[colIndex - 1], previous, distance[colIndex])
                }

                previous = temp
            }
        }

        let editDistance = distance[b.count]
        let similarity = 1 - (Double(editDistance) / Double(max(a.count, b.count)))
        return (editDistance, similarity)
    }
}
