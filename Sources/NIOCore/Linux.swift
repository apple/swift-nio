//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// This is a companion to System.swift that provides only Linux specials: either things that exist
// only on Linux, or things that have Linux-specific extensions.

#if os(Linux) || os(Android)
import CNIOLinux

#if canImport(Android)
@preconcurrency import Android
#endif

enum Linux {
    static let cfsQuotaPath = "/sys/fs/cgroup/cpu/cpu.cfs_quota_us"
    static let cfsPeriodPath = "/sys/fs/cgroup/cpu/cpu.cfs_period_us"
    static let cfsCpuMaxPath = "/sys/fs/cgroup/cpu.max"

    static let cpuSetPathV1 = "/sys/fs/cgroup/cpuset/cpuset.cpus"
    static let cpuSetPathV2: String? = {
        if let cgroupV2MountPoint = Self.cgroupV2MountPoint {
            return "\(cgroupV2MountPoint)/cpuset.cpus"
        }
        return nil
    }()

    static let cgroupV2MountPoint: String? = {
        guard
            let fd = try? SystemCalls.open(file: "/proc/self/cgroup", oFlag: O_RDONLY, mode: NIOPOSIXFileMode(S_IRUSR))
        else { return nil }
        defer { try! SystemCalls.close(descriptor: fd) }
        guard let lines = try? Self.readLines(descriptor: fd) else { return nil }

        // Parse each line looking for cgroup v2 format: "0::/path"
        for line in lines {
            if let cgroupPath = Self.parseV2CgroupLine(line) {
                return "/sys/fs/cgroup\(cgroupPath)"
            }
        }

        return nil
    }()

    /// Returns the appropriate cpuset path based on the detected cgroup version
    static let cpuSetPath: String? = {
        guard let version = Self.cgroupVersion else { return nil }

        switch version {
        case .v1:
            return cpuSetPathV1
        case .v2:
            return cpuSetPathV2
        }
    }()

    /// Detects whether we're using cgroup v1 or v2
    static let cgroupVersion: CgroupVersion? = {
        guard let type = try? SystemCalls.statfs_ftype("/sys/fs/cgroup") else { return nil }

        switch type {
        case CNIOLinux_TMPFS_MAGIC:
            return .v1
        case CNIOLinux_CGROUP2_SUPER_MAGIC:
            return .v2
        default:
            return nil
        }
    }()

    enum CgroupVersion {
        case v1
        case v2
    }

    /// Parses a single line from /proc/self/cgroup to extract cgroup v2 path
    internal static func parseV2CgroupLine(_ line: Substring) -> String? {
        // Expected format is "0::/path"
        let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)

        guard parts.count == 3,
            parts[0] == "0",
            parts[1] == ""
        else {
            return nil
        }

        // Extract the path from parts[2]
        return String(parts[2])
    }

    private static func readLines(descriptor: CInt) throws -> [Substring] {
        // linux doesn't properly report /sys/fs/cgroup/* files lengths so we use a reasonable limit
        var buf = ByteBufferAllocator().buffer(capacity: 1024)
        try buf.writeWithUnsafeMutableBytes(minimumWritableBytes: buf.capacity) { ptr in
            let res = try SystemCalls.read(descriptor: descriptor, pointer: ptr.baseAddress!, size: ptr.count)

            switch res {
            case .processed(let n):
                return n
            case .wouldBlock:
                preconditionFailure("read returned EWOULDBLOCK despite a blocking fd")
            }
        }
        return String(buffer: buf).split(separator: "\n")
    }

    private static func firstLineOfFile(path: String) throws -> Substring? {
        guard let fd = try? SystemCalls.open(file: path, oFlag: O_RDONLY, mode: NIOPOSIXFileMode(S_IRUSR)) else {
            return nil
        }
        defer { try! SystemCalls.close(descriptor: fd) }
        return try? Self.readLines(descriptor: fd).first
    }

    private static func countCoreIds(cores: Substring) -> Int {
        let ids = cores.split(separator: "-", maxSplits: 1)
        guard
            let first = ids.first.flatMap({ Int($0, radix: 10) }),
            let last = ids.last.flatMap({ Int($0, radix: 10) }),
            last >= first
        else { preconditionFailure("cpuset format is incorrect") }
        return 1 + last - first
    }

    static func coreCount(cpuset cpusetPath: String) -> Int? {
        guard
            let cpuset = try? firstLineOfFile(path: cpusetPath).flatMap({ $0.split(separator: ",") }),
            !cpuset.isEmpty
        else { return nil }
        return cpuset.map(countCoreIds).reduce(0, +)
    }

    /// Get the available core count according to cgroup1 restrictions.
    /// Round up to the next whole number.
    static func coreCountCgroup1Restriction(
        quota quotaPath: String = Linux.cfsQuotaPath,
        period periodPath: String = Linux.cfsPeriodPath
    ) -> Int? {
        guard
            let quota = try? firstLineOfFile(path: quotaPath).flatMap({ Int($0) }),
            quota > 0
        else { return nil }
        guard
            let period = try? firstLineOfFile(path: periodPath).flatMap({ Int($0) }),
            period > 0
        else { return nil }
        return (quota - 1 + period) / period  // always round up if fractional CPU quota requested
    }

    /// Get the available core count according to cgroup2 restrictions.
    /// Round up to the next whole number.
    static func coreCountCgroup2Restriction(cpuMaxPath: String = Linux.cfsCpuMaxPath) -> Int? {
        guard let maxDetails = try? firstLineOfFile(path: cpuMaxPath),
            let spaceIndex = maxDetails.firstIndex(of: " "),
            let quota = Int(maxDetails[maxDetails.startIndex..<spaceIndex]),
            let period = Int(maxDetails[maxDetails.index(after: spaceIndex)..<maxDetails.endIndex])
        else { return nil }
        return (quota - 1 + period) / period  // always round up if fractional CPU quota requested
    }
}
#endif
