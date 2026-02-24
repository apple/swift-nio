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

#pragma once

#include <inttypes.h>

extern _Thread_local uintptr_t _c_nio_posix_thread_local_el_id;

static inline uintptr_t c_nio_posix_get_el_id(void) {
    return _c_nio_posix_thread_local_el_id;
}

static inline void c_nio_posix_set_el_id(uintptr_t id) {
    _c_nio_posix_thread_local_el_id = id;
}
