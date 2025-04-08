//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if !canImport(Darwin) || os(macOS)
import NIOCore
import NIOPosix
import class Foundation.Process
import struct Foundation.URL
import class Foundation.FileHandle

struct CrashTest {
    let crashRegex: String
    let runTest: () -> Void

    init(regex: String, _ runTest: @escaping () -> Void) {
        self.crashRegex = regex
        self.runTest = runTest
    }
}

// Compatible with Swift on all macOS versions as well as Linux
extension Process {
    var binaryPath: String? {
        get {
            if #available(macOS 10.13, *) {
                return self.executableURL?.path
            } else {
                return self.launchPath
            }
        }
        set {
            if #available(macOS 10.13, *) {
                self.executableURL = newValue.map { URL(fileURLWithPath: $0) }
            } else {
                self.launchPath = newValue
            }
        }
    }

    func runProcess() throws {
        if #available(macOS 10.13, *) {
            try self.run()
        } else {
            self.launch()
        }
    }
}

func main() throws {
    enum RunResult {
        case signal(Int)
        case exit(Int)
    }

    enum InterpretedRunResult {
        case crashedAsExpected
        case regexDidNotMatch(regex: String, output: String)
        case unexpectedRunResult(RunResult)
        case outputError(String)
    }

    struct CrashTestNotFound: Error {
        let suite: String
        let test: String
    }

    func allTestsForSuite(_ testSuite: String) -> [(String, CrashTest)] {
        let crashTestSuites = makeCrashTestSuites()
        return crashTestSuites[testSuite].map { testSuiteObject in
            Mirror(reflecting: testSuiteObject)
                .children
                .filter { $0.label?.starts(with: "test") ?? false }
                .compactMap { crashTestDescriptor in
                    crashTestDescriptor.label.flatMap { label in
                        (crashTestDescriptor.value as? CrashTest).map { crashTest in
                            (label, crashTest)
                        }
                    }
                }
        } ?? []
    }

    func findCrashTest(_ testName: String, suite: String) -> CrashTest? {
        allTestsForSuite(suite)
            .first(where: { $0.0 == testName })?
            .1
    }

    func interpretOutput(
        _ result: Result<ProgramOutput, Error>,
        regex: String,
        runResult: RunResult
    ) throws -> InterpretedRunResult {
        struct NoOutputFound: Error {}
        #if arch(i386) || arch(x86_64)
        let expectedSignal = SIGILL
        #elseif arch(arm) || arch(arm64)
        let expectedSignal = SIGTRAP
        #else
        #error("unknown CPU architecture for which we don't know the expected signal for a crash")
        #endif
        guard case .signal(Int(expectedSignal)) = runResult else {
            return .unexpectedRunResult(runResult)
        }

        let output = try result.get()
        if output.range(of: regex, options: .regularExpression) != nil {
            return .crashedAsExpected
        } else {
            return .regexDidNotMatch(regex: regex, output: output)
        }
    }

    func usage() {
        print("\(CommandLine.arguments.first ?? "NIOCrashTester") COMMAND [OPTIONS]")
        print()
        print("COMMAND is:")
        print("  run-all                         to run all crash tests")
        print("  run SUITE TEST-NAME             to run the crash test SUITE.TEST-NAME")
        print("")
        print("For debugging purposes, you can also directly run the crash test binary that will crash using")
        print("  \(CommandLine.arguments.first ?? "NIOCrashTester") _exec SUITE TEST-NAME")
    }

    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer {
        try! group.syncShutdownGracefully()
    }

    // explicit return type needed due to https://github.com/apple/swift-nio/issues/3180
    let _: ((Int32) -> Void)? = signal(SIGPIPE, SIG_IGN)

    func runCrashTest(_ name: String, suite: String, binary: String) throws -> InterpretedRunResult {
        guard let crashTest = findCrashTest(name, suite: suite) else {
            throw CrashTestNotFound(suite: suite, test: name)
        }

        let grepper = OutputGrepper.make(group: group)

        let devNull = try FileHandle(forUpdating: URL(fileURLWithPath: "/dev/null"))
        defer {
            devNull.closeFile()
        }

        let processOutputPipe = FileHandle(fileDescriptor: try! grepper.processOutputPipe.takeDescriptorOwnership())
        let process = Process()
        process.binaryPath = binary
        process.standardInput = devNull
        process.standardOutput = devNull
        process.standardError = processOutputPipe

        process.arguments = ["_exec", suite, name]
        try process.runProcess()

        process.waitUntilExit()
        processOutputPipe.closeFile()
        let result: Result<ProgramOutput, Error> = Result {
            try grepper.result.wait()
        }
        return try interpretOutput(
            result,
            regex: crashTest.crashRegex,
            runResult: process.terminationReason == .exit
                ? .exit(Int(process.terminationStatus)) : .signal(Int(process.terminationStatus))
        )
    }

    var failedTests = 0
    func runAndEval(_ test: String, suite: String) throws {
        print("running crash test \(suite).\(test)", terminator: " ")
        switch try runCrashTest(test, suite: suite, binary: CommandLine.arguments.first!) {
        case .regexDidNotMatch(let regex, let output):
            print(
                "FAILED: regex did not match output",
                "regex: \(regex)",
                "output: \(output)",
                separator: "\n",
                terminator: ""
            )
            failedTests += 1
        case .unexpectedRunResult(let runResult):
            print("FAILED: unexpected run result: \(runResult)")
            failedTests += 1
        case .outputError(let description):
            print("FAILED: \(description)")
            failedTests += 1
        case .crashedAsExpected:
            print("OK")
        }
    }

    switch CommandLine.arguments.dropFirst().first {
    case .some("run-all"):
        let crashTestSuites = makeCrashTestSuites()
        for testSuite in crashTestSuites {
            for test in allTestsForSuite(testSuite.key) {
                try runAndEval(test.0, suite: testSuite.key)
            }
        }
    case .some("run"):
        if let suite = CommandLine.arguments.dropFirst(2).first {
            for test in CommandLine.arguments.dropFirst(3) {
                try runAndEval(test, suite: suite)
            }
        } else {
            usage()
            exit(EXIT_FAILURE)
        }
    case .some("_exec"):
        if let testSuiteName = CommandLine.arguments.dropFirst(2).first,
            let testName = CommandLine.arguments.dropFirst(3).first,
            let crashTest = findCrashTest(testName, suite: testSuiteName)
        {
            crashTest.runTest()
        } else {
            fatalError("can't find/create test for \(Array(CommandLine.arguments.dropFirst(2)))")
        }
    default:
        usage()
        exit(EXIT_FAILURE)
    }

    exit(CInt(failedTests == 0 ? EXIT_SUCCESS : EXIT_FAILURE))
}

try main()
#endif
