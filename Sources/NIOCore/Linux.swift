//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
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
enum Linux {
    static let cfsQuotaPath = "/sys/fs/cgroup/cpu/cpu.cfs_quota_us"
    static let cfsPeriodPath = "/sys/fs/cgroup/cpu/cpu.cfs_period_us"
    static let cpuSetPath = "/sys/fs/cgroup/cpuset/cpuset.cpus"

    private static func firstLineOfFile(path: String) throws -> Substring {
        let fh = try NIOFileHandle(path: path)
        defer { try! fh.close() }
        // linux doesn't properly report /sys/fs/cgroup/* files lengths so we use a reasonable limit
        var buf = ByteBufferAllocator().buffer(capacity: 1024)
        try buf.writeWithUnsafeMutableBytes(minimumWritableBytes: buf.capacity) { ptr in
            let res = try fh.withUnsafeFileDescriptor { fd -> CoreIOResult<ssize_t> in
                return try SystemCalls.read(descriptor: fd, pointer: ptr.baseAddress!, size: ptr.count)
            }
            switch res {
            case .processed(let n):
                return n
            case .wouldBlock:
                preconditionFailure("read returned EWOULDBLOCK despite a blocking fd")
            }
        }
        return String(buffer: buf).prefix(while: { $0 != "\n" })
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
            let cpuset = try? firstLineOfFile(path: cpusetPath).split(separator: ","),
            !cpuset.isEmpty
        else { return nil }
        return cpuset.map(countCoreIds).reduce(0, +)
    }

    static func coreCount(quota quotaPath: String,  period periodPath: String) -> Int? {
        guard
            let quota = try? Int(firstLineOfFile(path: quotaPath)),
            quota > 0
        else { return nil }
        guard
            let period = try? Int(firstLineOfFile(path: periodPath)),
            period > 0
        else { return nil }
        return (quota - 1 + period) / period // always round up if fractional CPU quota requested
    }
}
#endif
