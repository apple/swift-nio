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
import RegexBuilder
import struct Foundation.Date
import struct Foundation.Calendar
import class Foundation.FileManager

@available(macOS 13.0, *)
struct CopyrightCheck {
    private static let earliestValidYear = 2017
    private var options: Soundness.Options

    init(options: Soundness.Options) {
        self.options = options
    }

    func check() async throws -> [SoundnessResult] {
        let dateComponents = Calendar.current.dateComponents(in: .current, from: Date())
        let thisYear = dateComponents.year!
        let acceptableYears = Self.earliestValidYear...thisYear

        if self.options.verbose {
            print("Checking license headers...")
        }
        return try await withThrowingTaskGroup(of: SoundnessResult?.self) { group in
            for url in self.options.files {
                group.addTask {
                    let path = url.path(percentEncoded: false)

                    if self.options.shouldIgnore(url: url) {
                        return .skipped(path)
                    }

                    guard FileManager.default.fileExistsAndIsNotDirectory(atPath: path) else {
                        // Ignore directories
                        return nil
                    }

                    let contents = try String(contentsOf: url)
                    let regex = Regex {
                        ChoiceOf {
                            CopyrightHeaderRegex(
                                headerLinePrefix: "//",
                                headerLineSuffix: "//",
                                footerLinePrefix: "//",
                                footerLineSuffix: "//",
                                linePrefix: "//"
                            )
                            CopyrightHeaderRegex(
                                headerLinePrefix: "##",
                                headerLineSuffix: "##",
                                footerLinePrefix: "##",
                                footerLineSuffix: "##",
                                linePrefix: "##"
                            )
                            CopyrightHeaderRegex(
                                headerLinePrefix: "/*",
                                headerLineSuffix: "*",
                                footerLinePrefix: " *",
                                footerLineSuffix: "*/",
                                linePrefix: " *"
                            )
                        }
                    }

                    let result: CopyrightValidationResult

                    if let match = contents.firstMatch(of: regex) {
                        if let years = match.output.1 {
                            result = years.validate(within: acceptableYears)
                        } else if let years = match.output.2 {
                            result = years.validate(within: acceptableYears)
                        } else if let years = match.output.3 {
                            result = years.validate(within: acceptableYears)
                        } else {
                            // There's a choice of three regexes to match. We covered them above so
                            // this must not fail.
                            preconditionFailure()
                        }
                    } else {
                        result = .noMatch
                    }

                    switch result {
                    case .valid:
                        return .passed(path)
                    case .noMatch:
                        return .failed(path, reason: "invalid or missing copyright header")
                    case let .invalidStartYear(year, earliest):
                        return .failed(path, reason: "start year \(year) must be >= \(earliest)")
                    case let .invalidEndYear(year, latest):
                        return .failed(path, reason: "end year \(year) must be <= \(latest)")
                    case let .invalidRange(start, end):
                        return .failed(path, reason: "year range \(start)-\(end) is invalud (\(start) must be < \(end))")
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

enum CopyrightYears: Hashable {
    /// An exact year, e.g. '2022'
    case exact(Int)
    /// A range of years, e.g. '2017-2020'
    case range(start: Int, end: Int)
}

enum CopyrightValidationResult: Sendable {
    case valid
    case noMatch
    case invalidStartYear(Int, earliestStartYear: Int)
    case invalidEndYear(Int, latestEndYear: Int)
    case invalidRange(Int, Int)
}

extension CopyrightYears {
    func validate(within validYears: ClosedRange<Int>) -> CopyrightValidationResult {
        switch self {
        case let .exact(year):
            if year < validYears.lowerBound {
                return .invalidStartYear(year, earliestStartYear: validYears.lowerBound)
            } else if year > validYears.upperBound {
                return .invalidEndYear(year, latestEndYear: validYears.upperBound)
            } else {
                return .valid
            }

        case let .range(start, end):
            if end <= start {
                return .invalidRange(start, end)
            } else if start < validYears.lowerBound {
                return .invalidStartYear(start, earliestStartYear: validYears.lowerBound)
            } else if end > validYears.upperBound {
                return .invalidEndYear(end, latestEndYear: validYears.upperBound)
            } else {
                return .valid
            }
        }
    }
}

@available(macOS 13.0, *)
struct CopyrightHeaderRegex: RegexComponent {
    let headerLinePrefix: String
    let headerLineSuffix: String

    let footerLinePrefix: String
    let footerLineSuffix: String

    let linePrefix: String

    private var headerLine: String {
        return self.headerLinePrefix
            + String(repeating: "=", count: 3)
            + String(repeating: "-", count: 70)
            + String(repeating: "=", count: 3)
            + self.headerLineSuffix
            + "\n"
    }

    private var footerLine: String {
        return self.footerLinePrefix
            + String(repeating: "=", count: 3)
            + String(repeating: "-", count: 70)
            + String(repeating: "=", count: 3)
            + self.footerLineSuffix
            + "\n"
    }

    private func prefixed(_ line: String, newline: Bool = true) -> String {
        if newline {
            return self.linePrefix + line + "\n"
        } else {
            return self.linePrefix + line
        }
    }

    var regex: Regex<(Substring, CopyrightYears)> {
        return Regex {
            self.headerLine
            self.prefixed("")
            self.prefixed(" This source file is part of the SwiftNIO open source project")
            self.prefixed("")
            self.prefixed(" Copyright (c) ", newline: false)
            TryCapture {
                ChoiceOf {
                    #/\d{4}/#
                    #/\d{4}-\d{4}/#
                }
            } transform: { capture -> CopyrightYears? in
                if let index = capture.firstIndex(of: "-") {
                    if let startYear = Int(capture[..<index]),
                       let endYear = Int(capture[capture.index(after: index)...]) {
                        return CopyrightYears.range(start: startYear, end: endYear)
                    } else {
                        return nil
                    }
                } else {
                    return Int(capture).map { CopyrightYears.exact($0) }
                }
            }
            " Apple Inc. and the SwiftNIO project authors\n"
            self.prefixed(" Licensed under Apache License v2.0")
            self.prefixed("")
            self.prefixed(" See LICENSE.txt for license information")
            self.prefixed(" See CONTRIBUTORS.txt for the list of SwiftNIO project authors")
            self.prefixed("")
            self.prefixed(" SPDX-License-Identifier: Apache-2.0")
            self.prefixed("")
            self.footerLine
        }
    }
}
#endif // swift(>=5.7)
