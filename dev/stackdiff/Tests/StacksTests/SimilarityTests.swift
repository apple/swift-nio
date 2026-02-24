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

struct SimilarityTests {
    @Test(arguments: ["", "foo", "Foo"])
    func perfectMatch(_ input: String) {
        let (distance, score) = Similarity.levenshtein(input, input)
        #expect(distance == 0)
        #expect(score == 1)
    }

    @Test(arguments: [("", "a"), ("a", ""), ("a", "b"), ("A", "a")])
    func maxDistance(_ lhs: String, _ rhs: String) {
        let (distance, score) = Similarity.levenshtein(lhs, rhs)
        #expect(distance == 1)
        #expect(score == 0)
    }

    @Test
    func kittenSitting() {
        let (distance, _) = Similarity.levenshtein("kitten", "sitting")
        // k -> s
        // e -> i
        // +g
        #expect(distance == 3)
    }

    @Test
    func similarityScore() {
        let (distance, similarity) = Similarity.levenshtein("aa", "bbaa")
        // +b
        // +b
        #expect(distance == 2)
        // = 1 - lev(aa, bbaa) / max(len(aa), len(bbaa))
        // = 1 - (2) / max(2, 4)
        // = 1 - 2 / 4
        // = 1 - 0.5
        // = 0.5
        #expect(similarity == 0.5)
    }
}
