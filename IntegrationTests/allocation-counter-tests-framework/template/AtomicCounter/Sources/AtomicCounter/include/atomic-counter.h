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

#ifndef ATOMIC_COUNTER
#define ATOMIC_COUNTER

#include <stdatomic.h>

void inc_free_counter(void);
void reset_free_counter(void);
long read_free_counter(void);

void inc_malloc_counter(void);
void reset_malloc_counter(void);
long read_malloc_counter(void);

void add_malloc_bytes_counter(intptr_t v);
void reset_malloc_bytes_counter(void);
intptr_t read_malloc_bytes_counter(void);

#endif
