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

#ifndef HOOKED_FREE
#define HOOKED_FREE

#include <stdlib.h>
#if __APPLE__
#  include <malloc/malloc.h>
#endif

void *replacement_malloc(size_t size);
void replacement_free(void *ptr);
void *replacement_calloc(size_t nmemb, size_t size);
void *replacement_realloc(void *ptr, size_t size);
void *replacement_reallocf(void *ptr, size_t size);
void *replacement_valloc(size_t size);
int replacement_posix_memalign(void **memptr, size_t alignment, size_t size);

#if __APPLE__
void *replacement_malloc_zone_malloc(malloc_zone_t *zone, size_t size);
void *replacement_malloc_zone_calloc(malloc_zone_t *zone, size_t num_items, size_t size);
void *replacement_malloc_zone_valloc(malloc_zone_t *zone, size_t size);
void *replacement_malloc_zone_realloc(malloc_zone_t *zone, void *ptr, size_t size);
void *replacement_malloc_zone_memalign(malloc_zone_t *zone, size_t alignment, size_t size);
void replacement_malloc_zone_free(malloc_zone_t *zone, void *ptr);
#endif

#endif
