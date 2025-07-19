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

#include "include/CNIOPosix.h"

// Once we support C23, this should become `thread_local`.
// DO NOT TOUCH DIRECTLY, use `c_nio_posix_{get,set}_el_id`
_Thread_local uintptr_t _c_nio_posix_thread_local_el_id;
