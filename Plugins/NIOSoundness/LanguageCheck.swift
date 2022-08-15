//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
#if swift(>=5.7)
import class Foundation.FileManager
import struct Foundation.URL

@available(macOS 13.0, *)
struct LanguageCheck {
    private var options: Soundness.Options

    init(options: Soundness.Options) {
        self.options = options
    }

    func check() async throws -> [SoundnessResult] {
        if self.options.verbose {
            print("Checking lanuage...")
        }
        return try await withThrowingTaskGroup(of: SoundnessResult?.self) { group in
            for url in self.options.files {
                group.addTask {
                    let path = url._path

                    if self.options.shouldIgnore(url: url) {
                        return .skipped(path)
                    }

                    guard FileManager.default.fileExistsAndIsNotDirectory(atPath: path) else {
                        // Ignore directories.
                        return nil
                    }

                    let contents = try String(contentsOf: url)
                    let regex = #/(?<term>blacklis[t]|whitelis[t]|slav[e]|sanit[y])/#

                    if let match = contents.firstMatch(of: regex) {
                        return .failed(path, reason: "contains unacceptable term '\(match.output.term)'")
                    } else {
                        return .passed(path)
                    }
                }
            }

            var results: [SoundnessResult] = []
            for try await result in group.compactMap({ $0 }) {
                results.append(result)
            }
            return results
        }
    }
}
#endif // swift(>=5.7)
