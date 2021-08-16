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

#if os(Linux) || os(Android)
import CNIOLinux

    /// A set that contains CPU ids to use.
    struct LinuxCPUSet {
        /// The ids of all the cpus.
        let cpuIds: Set<Int>

        /// Create a new instance
        ///
        /// - arguments:
        ///     - cpuIds: The `Set` of CPU ids. It must be non-empty and can not contain invalid ids.
        init(cpuIds: Set<Int>) {
            precondition(!cpuIds.isEmpty)
            self.cpuIds = cpuIds
        }

        /// Create a new instance
        ///
        /// - arguments:
        ///     - cpuId: The CPU id.
        init(_ cpuId: Int) {
            let ids: Set<Int> = [cpuId]
            self.init(cpuIds: ids)
        }
    }

    extension LinuxCPUSet: Equatable {}

    /// Linux specific extension to `NIOThread`.
    extension NIOThread {
        /// Specify the thread-affinity of the `NIOThread` itself.
        var affinity: LinuxCPUSet {
            get {
                var cpuset = cpu_set_t()

                // Ensure the cpuset is empty (and so nothing is selected yet).
                CNIOLinux_CPU_ZERO(&cpuset)

                let res = self.withUnsafeThreadHandle { p in
                    CNIOLinux_pthread_getaffinity_np(p, MemoryLayout.size(ofValue: cpuset), &cpuset)
                }

                precondition(res == 0, "pthread_getaffinity_np failed: \(res)")

                let set = Set((CInt(0)..<CNIOLinux_CPU_SETSIZE()).lazy.filter { CNIOLinux_CPU_ISSET($0, &cpuset) != 0 }.map { Int($0) })
                return LinuxCPUSet(cpuIds: set)
            }
            set(cpuSet) {
                var cpuset = cpu_set_t()

                // Ensure the cpuset is empty (and so nothing is selected yet).
                CNIOLinux_CPU_ZERO(&cpuset)

                // Mark the CPU we want to run on.
                cpuSet.cpuIds.forEach { CNIOLinux_CPU_SET(CInt($0), &cpuset) }
                let res = self.withUnsafeThreadHandle { p in
                    CNIOLinux_pthread_setaffinity_np(p, MemoryLayout.size(ofValue: cpuset), &cpuset)
                }
                precondition(res == 0, "pthread_setaffinity_np failed: \(res)")
            }
        }
    }

    extension MultiThreadedEventLoopGroup {

        /// Create a new `MultiThreadedEventLoopGroup` that create as many `NIOThread`s as `pinnedCPUIds`. Each `NIOThread` will be pinned to the CPU with the id.
        ///
        /// - arguments:
        ///     - pinnedCPUIds: The CPU ids to apply to the `NIOThread`s.
        convenience init(pinnedCPUIds: [Int]) {
            let initializers: [ThreadInitializer]  = pinnedCPUIds.map { id in
                // This will also take care of validation of the provided id.
                let set = LinuxCPUSet(id)
                return { t in
                    t.affinity = set
                }
            }
            self.init(threadInitializers: initializers)
        }
    }
#endif
