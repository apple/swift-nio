//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if canImport(Darwin)
import Darwin.C
#elseif canImport(Glibc)
import Glibc
#else
#error("Unsupported platform.")
#endif

// This file allows us to hook the global executor which
// we can use to mimic task executors for now.
typealias EnqueueGlobalHook = @convention(thin) (UnownedJob, @convention(thin) (UnownedJob) -> Void) -> Void

var swiftTaskEnqueueGlobalHook: EnqueueGlobalHook? {
    get { _swiftTaskEnqueueGlobalHook.pointee }
    set { _swiftTaskEnqueueGlobalHook.pointee = newValue }
}

private let _swiftTaskEnqueueGlobalHook: UnsafeMutablePointer<EnqueueGlobalHook?> =
    dlsym(dlopen(nil, RTLD_LAZY), "swift_task_enqueueGlobal_hook").assumingMemoryBound(to: EnqueueGlobalHook?.self)
