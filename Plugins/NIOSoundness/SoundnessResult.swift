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

/// The result of a soundness check on a file.
struct SoundnessResult: Hashable, Sendable {
    /// Path of file being checked.
    var path: String
    /// Outcome of the check.
    var outcome: Outcome

    private init(path: String, outcome: Outcome) {
        self.path = path
        self.outcome = outcome
    }

    /// The file passed the check.
    static func passed(_ path: String) -> Self {
        return .init(path: path, outcome: .pass)
    }

    /// The file was skipped.
    static func skipped(_ path: String) -> Self {
        return .init(path: path, outcome: .skipped)
    }

    /// The file failed the check.
    static func failed(_ path: String, reason: String) -> Self {
        return .init(path: path, outcome: .fail(reason))
    }

    /// 'true' if the result was a failure.
    var isFailure: Bool {
        switch self.outcome {
        case .fail:
            return true
        case .pass, .skipped:
            return false
        }
    }

    enum Outcome: Hashable, Sendable {
        case pass
        case skipped
        case fail(String)
    }
}

extension SoundnessResult: CustomStringConvertible {
    var description: String {
        switch self.outcome {
        case .pass:
            return "[✓] \(self.path)"
        case .skipped:
            return "[s] \(self.path)"
        case let .fail(reason):
            return "[×] \(self.path), reason: \(reason)"
        }
    }
}
#endif // swift(>=5.7)
