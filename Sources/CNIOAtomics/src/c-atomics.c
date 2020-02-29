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

#include <stdlib.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <inttypes.h>
#include <stdio.h>

#include "../include/CNIOAtomics.h"
#include "cpp_magic.h"

#define MAKE(type) /*
*/ struct catmc_atomic_##type { /*
*/     _Atomic type value; /*
*/ }; /*
*/ /*
*/ struct catmc_atomic_##type *catmc_atomic_##type##_create(type value) { /*
*/     struct catmc_atomic_##type *wrapper = malloc(sizeof(*wrapper)); /*
*/     atomic_init(&wrapper->value, value); /*
*/     return wrapper; /*
*/ } /*
*/ /*
*/ void catmc_atomic_##type##_destroy(struct catmc_atomic_##type *wrapper) { /*
*/     free(wrapper); /*
*/ } /*
*/ /*
*/ bool catmc_atomic_##type##_compare_and_exchange(struct catmc_atomic_##type *wrapper, type expected, type desired) { /*
*/     type expected_copy = expected; /*
*/     return atomic_compare_exchange_strong(&wrapper->value, &expected_copy, desired); /*
*/ } /*
*/ /*
*/ type catmc_atomic_##type##_add(struct catmc_atomic_##type *wrapper, type value) { /*
*/     return atomic_fetch_add_explicit(&wrapper->value, value, memory_order_relaxed); /*
*/ } /*
*/ /*
*/ type catmc_atomic_##type##_sub(struct catmc_atomic_##type *wrapper, type value) { /*
*/     return atomic_fetch_sub_explicit(&wrapper->value, value, memory_order_relaxed); /*
*/ } /*
*/ /*
*/ type catmc_atomic_##type##_exchange(struct catmc_atomic_##type *wrapper, type value) { /*
*/     return atomic_exchange_explicit(&wrapper->value, value, memory_order_relaxed); /*
*/ } /*
*/ /*
*/ type catmc_atomic_##type##_load(struct catmc_atomic_##type *wrapper) { /*
*/     return atomic_load_explicit(&wrapper->value, memory_order_relaxed); /*
*/ } /*
*/ /*
*/ void catmc_atomic_##type##_store(struct catmc_atomic_##type *wrapper, type value) { /*
*/     atomic_store_explicit(&wrapper->value, value, memory_order_relaxed); /*
*/ }

typedef signed char signed_char;
typedef signed short signed_short;
typedef signed int signed_int;
typedef signed long signed_long;
typedef signed long long signed_long_long;
typedef unsigned char unsigned_char;
typedef unsigned short unsigned_short;
typedef unsigned int unsigned_int;
typedef unsigned long unsigned_long;
typedef unsigned long long unsigned_long_long;
typedef long long long_long;

MAP(MAKE,EMPTY,
         bool,
		          char,          short,          int,          long,          long_long,
		   signed_char,   signed_short,   signed_int,   signed_long,   signed_long_long,
		 unsigned_char, unsigned_short, unsigned_int, unsigned_long, unsigned_long_long,
		 int_least8_t, uint_least8_t,
		 int_least16_t, uint_least16_t,
		 int_least32_t, uint_least32_t,
		 int_least64_t, uint_least64_t,
		 intptr_t, uintptr_t
		)
