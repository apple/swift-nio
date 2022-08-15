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
import PackagePlugin
import Foundation

@main
@available(macOS 13.0, *)
struct Soundness: CommandPlugin {
    func performCommand(context: PackagePlugin.PluginContext, arguments: [String]) async throws {
        // Check for help first.
        if arguments.contains("--help") {
            print(Self.helpText)
            return
        }

        guard let command = arguments.first.flatMap({ Soundness.Check(rawValue: $0) }) else {
            throw SoundnessError.missingCommand
        }

        let options = try Self.Options(parsing: arguments.dropFirst()) // drop the command.

        let results: [SoundnessResult]

        switch command {
        case .licenseHeader:
            let copyright = CopyrightCheck(options: options)
            results = try await copyright.check()
        case .language:
            let language = LanguageCheck(options: options)
            results = try await language.check()
        }

        // Grab all failures and print them last so they're more discoverable.
        var failures: [SoundnessResult] = []

        for result in results {
            if result.isFailure {
                failures.append(result)
            } else if options.verbose {
                print(result)
            }
        }

        if failures.isEmpty {
            print("Checked \(results.count) files, no problems found.")
        } else {
            print("Checked \(results.count) files, found \(failures.count) issue(s):")
            for problem in failures {
                print(problem)
            }
            throw Soundness.SoundnessError.soundnessFailed
        }
    }

    static let helpText = """
    USAGE: nio-soundness <command> [--exclude-directory <directory>] [--exclude-extension <extension>] [--exclude-file <file>] <file> ...

    SUBCOMMANDS:
      check-license-header               Check a valid license header is present.
      check-language                     Check no unacceptable language is used.

    ARGUMENTS:
      <file>                             A list of files to check.

    OPTIONS:
      --exclude-directory <directory>    Ignore files in the directory.
      --exclude-extension <extension>    Ignore files with the extension.
      --exclude-file <file>              Ignore specific files.

    FLAGS:
      --verbose                          Enable verbose output.
      --help                             Prints this help message then exits.

    EXAMPLE:

      Run the license header check on all files found by globbing the Sources
      directory but ignore *.md and all files in the Sources/Vendored directory.

        nio-soundness check-license-header \\
          --exclude-extension md \\
          --exclude-directory Sources/Vendored \\
          Sources/**

    """
}

@available(macOS 13.0, *)
extension Soundness {
    enum SoundnessError: Error, CustomStringConvertible {
        case missingValue(String)
        case missingCommand
        case noFiles
        case soundnessFailed

        var description: String {
            switch self {
            case let .missingValue(option):
                return "No value specified for option '\(option)'"
            case .missingCommand:
                return "Invalid or no command given (try --help)"
            case .noFiles:
                return "At least one file must be specified"
            case .soundnessFailed:
                return "Soundness check failed; check output for details"
            }
        }
    }
}

@available(macOS 13.0, *)
extension Soundness {
    private enum Check: String {
        case licenseHeader = "check-license-header"
        case language = "check-language"
    }

    struct Options: Hashable {
        var excludedExtensions = [String]()
        var excludedDirectories = [URL]()
        var excludedFiles = [URL]()
        var files = [URL]()
        var verbose = false

        init<Args: Collection>(parsing arguments: Args) throws where Args.Element == String {
            var index = arguments.startIndex
            while index != arguments.endIndex {
                let argument = arguments[index]

                if let flag = Flag(rawValue: argument) {
                    switch flag {
                    case .verbose:
                        self.verbose = true
                    }
                } else if let option = Name(rawValue: argument) {
                    arguments.formIndex(after: &index)

                    guard index != arguments.endIndex else {
                        throw SoundnessError.missingValue(argument)
                    }

                    let value = arguments[index]

                    switch option {
                    case .excludeExtension:
                        self.excludedExtensions.append(value)
                    case .excludeDirectory:
                        self.excludedDirectories.append(URL(_filePath: value))
                    case .excludeFile:
                        self.excludedFiles.append(URL(_filePath: value))
                    }

                } else {
                    // Not a flag/option: must be arguments
                    self.files.append(contentsOf: arguments[index...].map { URL(_filePath: $0) })
                    break
                }
                arguments.formIndex(after: &index)
            }

            if self.files.isEmpty {
                throw SoundnessError.noFiles
            }
        }

        fileprivate enum Flag: String {
            case verbose = "--verbose"
        }

        fileprivate enum Name: String {
            case excludeExtension = "--exclude-extension"
            case excludeDirectory = "--exclude-directory"
            case excludeFile = "--exclude-file"
        }
    }
}

@available(macOS 13.0, *)
extension Soundness.Options {
    func shouldIgnore(url: URL) -> Bool {
        return self.excludedFiles.contains(url)
            || self.excludedExtensions.contains(url.pathExtension)
            || self.excludedDirectories.contains { url.absoluteString.utf8.starts(with: $0.absoluteString.utf8) }
    }
}

extension URL {
    @available(macOS 13.0, *)
    init(_filePath: String) {
        // 'init(fileURLWithPath)' is deprecated on macOS, but 'init(filePath:)' hasn't made it
        // to swift-corelibs-foundation.
        // https://github.com/apple/swift-corelibs-foundation/issues/4623
        #if os(macOS)
        self = .init(filePath: _filePath)
        #else
        self = .init(fileURLWithPath: _filePath)
        #endif
    }

    @available(macOS 13.0, *)
    var _path: String {
        // 'path' is deprecated on macOS, but 'path(percentEncoded:)' hasn't made it
        // to swift-corelibs-foundation.
        // https://github.com/apple/swift-corelibs-foundation/issues/4623
        #if os(macOS)
        return self.path(percentEncoded: false)
        #else
        return self.path
        #endif
    }
}

extension FileManager {
    func fileExistsAndIsNotDirectory(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false

        if self.fileExists(atPath: path, isDirectory: &isDirectory) {
            return !isDirectory.boolValue
        } else {
            return false
        }
    }
}
#else
import PackagePlugin
import Foundation

@main
struct Soundness: CommandPlugin {
    struct UnsupportedVersion: Error, CustomStringConvertible {
        var description: String {
            return "nio-soundness requires Swift >= 5.7"
        }
    }

    func performCommand(context: PluginContext, arguments: [String]) async throws {
        throw UnsupportedVersion()
    }
}
#endif // swift(>=5.7)
