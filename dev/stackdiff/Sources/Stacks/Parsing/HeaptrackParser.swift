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

import Foundation

/// Parses output from `heaptrack analyze`.
public struct HeaptrackParser: StackParser {
    private let regex = /^(\d+) calls with/
    private var state: ParseState
    private var stacks: [WeightedStack]

    private init() {
        self.stacks = []
        self.state = .parsingHeader
    }

    private enum ParseResult {
        case needsNextLine
        case parsedStack(Stack, Int)
    }

    private enum ParseState {
        case parsingHeader
        case parsingStack(ParsingStackState)
    }

    private struct ParsingStackState {
        var count: Int
        var lines: [String]

        init(count: Int) {
            self.count = count
            self.lines = []
        }

        private static var prefixesToIgnore: [String] {
            ["      in", "      at", "    0x"]
        }

        mutating func parse(_ line: String) -> (ParseState, ParseResult) {
            if Self.prefixesToIgnore.contains(where: { line.contains($0) }) {
                return (.parsingStack(self), .needsNextLine)
            } else if line.starts(with: "    ") {
                self.lines.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
                return (.parsingStack(self), .needsNextLine)
            } else {
                return (.parsingHeader, .parsedStack(Stack(self.lines), self.count))
            }
        }
    }

    /// Parses input which looks roughly like the following:
    ///
    /// ```
    /// reading file "heaptrack.simple-handshake.b.gz" - please wait, this might take some time...
    /// Debuggee command was: ./.build/release/simple-handshake
    /// finished reading file, now analyzing data:
    ///
    /// MOST CALLS TO ALLOCATION FUNCTIONS
    /// 488867 calls to allocation functions with 28.16K peak consumption from
    /// CNIOBoringSSL_OPENSSL_malloc
    ///   at Sources/CNIOBoringSSL/crypto/mem.cc:249
    ///   in /code/.build/aarch64-unknown-linux-gnu/release/simple-handshake
    /// 3000 calls with 80B peak consumption from:
    ///   CNIOBoringSSL_OPENSSL_zalloc
    ///     at Sources/CNIOBoringSSL/crypto/mem.cc:266
    ///     in /code/.build/aarch64-unknown-linux-gnu/release/simple-handshake
    ///   CNIOBoringSSL_ASN1_item_ex_new
    ///     at Sources/CNIOBoringSSL/crypto/asn1/tasn_new.cc:153
    /// ...
    ///   __libc_start_main
    ///     in /lib/aarch64-linux-gnu/libc.so.6
    /// 3000 calls with 96B peak consumption from:
    ///   CNIOBoringSSL_ASN1_STRING_type_new
    ///     at Sources/CNIOBoringSSL/crypto/asn1/asn1_lib.cc:329
    ///     in /code/.build/aarch64-unknown-linux-gnu/release/simple-handshake
    ///   ASN1_primitive_new(ASN1_VALUE_st**, ASN1_ITEM_st const*)
    /// ...
    /// ```
    private mutating func parse(lines: some Sequence<String>) -> [WeightedStack] {
        for line in lines {
            loop: while true {
                switch self.parseNextState(line) {
                case .parsedStack(let stack, let count):
                    self.stacks.append(WeightedStack(stack: stack, allocations: count))

                case .needsNextLine:
                    break loop
                }
            }
        }

        return self.stacks
    }

    private mutating func parseNextState(_ line: String) -> ParseResult {
        switch self.state {
        case .parsingHeader:
            return self.parseHeader(line)

        case .parsingStack(var state):
            let (state, result) = state.parse(line)
            self.state = state
            return result
        }
    }

    private mutating func parseHeader(_ line: String) -> ParseResult {
        if let match = line.firstMatch(of: self.regex) {
            // At the start of a stack.
            guard let count = Int(match.1) else {
                fatalError("Failed to convert '\(match.1)' to an Int")
            }

            self.state = .parsingStack(ParsingStackState(count: count))
        }

        return .needsNextLine
    }
}

extension HeaptrackParser {
    public static func parse(lines: some Sequence<String>) -> [WeightedStack] {
        var parser = Self()
        return parser.parse(lines: lines)
    }
}
