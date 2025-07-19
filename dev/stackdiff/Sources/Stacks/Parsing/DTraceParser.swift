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

/// Parses output from NIO's `malloc-aggregation.d` DTrace script.
public struct DTraceParser: StackParser {
    private static var allocationsRegex: Regex<(Substring, Substring)> {
        /^ +(\d+)$/
    }

    private var state: ParseState
    private var stacks: [WeightedStack]

    private init() {
        self.stacks = []
        self.state = .parsingHeader
    }

    private enum ParseResult {
        case `continue`
        case needsNextLine
        case parsedStack(Stack, Int)
    }

    private enum ParseState {
        case parsingHeader
        case parsingStack(ParsingStackState)
    }

    private struct ParsingStackState {
        var lines: [String]

        init() {
            self.lines = []
        }

        mutating func parse(_ line: String) -> (ParseState, ParseResult) {
            if let match = line.firstMatch(of: DTraceParser.allocationsRegex) {
                if let count = Int(match.1) {
                    return (.parsingHeader, .parsedStack(Stack(self.lines), count))
                } else {
                    fatalError("Failed to convert '\(match.1)' to an Int")
                }
            } else {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let split = trimmed.split(separator: "+0x")
                self.lines.append(split.first.map { String($0) } ?? trimmed)
                return (.parsingStack(self), .needsNextLine)
            }
        }
    }

    /// Parses input which looks roughly like the following:
    ///
    /// ```
    /// =====
    /// This will collect stack shots of allocations and print it when you exit dtrace.
    /// So go ahead, run your tests and then press Ctrl+C in this window to see the aggregated result
    /// =====
    /// 20896284696
    ///
    ///               libsystem_malloc.dylib`malloc_type_posix_memalign
    ///               libobjc.A.dylib`id2data(objc_object*, SyncKind, usage)+0x1a0
    ///               libobjc.A.dylib`_objc_sync_enter_kind+0x1c
    ///               libobjc.A.dylib`initializeNonMetaClass+0xa8
    ///               ...
    ///               libdispatch.dylib`_dispatch_client_callout+0x10
    ///               libdispatch.dylib`_dispatch_once_callout+0x20
    ///               libswiftCore.dylib`swift_getCanonicalPrespecializedGenericMetadata+0xc8
    ///               libswiftCore.dylib`__swift_instantiateCanonicalPrespecializedGenericMetadata+0x28
    ///               libswiftCore.dylib`_ContiguousArrayBuffer .init(_uninitializedCount:minimumCapacity:)+0x3c
    ///               do-some-allocs`specialized static do_some_allocs.main()+0x5c
    ///               do-some-allocs`do_some_allocs_main+0xc
    ///                 1
    ///
    ///               libsystem_malloc.dylib`malloc_type_posix_memalign
    ///               libobjc.A.dylib`id2data(objc_object*, SyncKind, usage)+0x1a0
    ///               libobjc.A.dylib`_objc_sync_enter_kind+0x1c
    ///               ...
    /// ```
    private mutating func parse(lines: some Sequence<String>) -> [WeightedStack] {
        for line in lines {
            loop: while true {
                switch self.parseNextState(line) {
                case .parsedStack(let stack, let count):
                    self.stacks.append(WeightedStack(stack: stack, allocations: count))
                    break loop

                case .continue:
                    ()

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
            if line.hasPrefix(" ") {
                // Loop around and parse the line as a stack.
                self.state = .parsingStack(ParsingStackState())
                return .continue
            } else {
                return .needsNextLine
            }

        case .parsingStack(var state):
            let (state, result) = state.parse(line)
            self.state = state
            return result
        }
    }
}

extension DTraceParser {
    public static func parse(lines: some Sequence<String>) -> [WeightedStack] {
        var parser = Self()
        return parser.parse(lines: lines)
    }
}
