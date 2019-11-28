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

#include <stdatomic.h>

#define MAKE_COUNTER(name) /*
*/ _Atomic long g_ ## name ## _counter = ATOMIC_VAR_INIT(0); /*
*/ void inc_ ## name ## _counter(void) { /*
*/    atomic_fetch_add_explicit(&g_ ## name ## _counter, 1, memory_order_relaxed); /*
*/ } /*
*/ /*
*/ void add_ ## name ## _counter(intptr_t v) { /*
*/    atomic_fetch_add_explicit(&g_ ## name ## _counter, v, memory_order_relaxed); /*
*/ } /*
*/ void reset_ ## name ## _counter(void) { /*
*/     atomic_store_explicit(&g_ ## name ## _counter, 0, memory_order_relaxed); /*
*/ } /*
*/ /*
*/ intptr_t read_ ## name ## _counter(void) { /*
*/     return atomic_load_explicit(&g_ ## name ## _counter, memory_order_relaxed); /*
*/ }

MAKE_COUNTER(free)
MAKE_COUNTER(malloc)
MAKE_COUNTER(malloc_bytes)
