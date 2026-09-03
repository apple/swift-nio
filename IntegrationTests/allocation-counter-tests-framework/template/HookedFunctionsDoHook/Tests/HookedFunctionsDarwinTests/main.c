//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#include <stdbool.h>
#include <stdio.h>

#if __APPLE__
#include <malloc/malloc.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <hooked-functions.h>

static bool test_zone_realloc_called = false;

static size_t test_zone_size(malloc_zone_t *zone, const void *ptr) {
    return malloc_size(ptr);
}

static void *test_zone_malloc(malloc_zone_t *zone, size_t size) {
    return malloc(size);
}

static void *test_zone_calloc(malloc_zone_t *zone, size_t count, size_t size) {
    return calloc(count, size);
}

static void *test_zone_valloc(malloc_zone_t *zone, size_t size) {
    void *ptr = NULL;
    if (posix_memalign(&ptr, (size_t)getpagesize(), size) != 0) {
        return NULL;
    }

    memset(ptr, 0, size);
    return ptr;
}

static void test_zone_free(malloc_zone_t *zone, void *ptr) {
    free(ptr);
}

static void *test_zone_realloc(malloc_zone_t *zone, void *ptr, size_t size) {
    test_zone_realloc_called = true;
    return realloc(ptr, size);
}

static void test_zone_destroy(malloc_zone_t *zone) {}

static bool replacement_malloc_zone_realloc_uses_zone(void) {
    malloc_zone_t zone = { 0 };
    zone.size = test_zone_size;
    zone.malloc = test_zone_malloc;
    zone.calloc = test_zone_calloc;
    zone.valloc = test_zone_valloc;
    zone.free = test_zone_free;
    zone.realloc = test_zone_realloc;
    zone.destroy = test_zone_destroy;
    zone.zone_name = "HookedFunctionsDarwinTests";
    zone.version = 4;

    void *ptr = malloc(16);
    if (!ptr) {
        return false;
    }

    test_zone_realloc_called = false;
    void *reallocated = replacement_malloc_zone_realloc(&zone, ptr, 32);
    bool did_use_zone = test_zone_realloc_called && reallocated != NULL;

    if (reallocated) {
        free(reallocated);
    } else {
        free(ptr);
    }

    return did_use_zone;
}
#endif

int main(void) {
#if __APPLE__
    if (!replacement_malloc_zone_realloc_uses_zone()) {
        fprintf(stderr, "replacement_malloc_zone_realloc did not use the requested malloc zone\n");
        return 1;
    }
#endif

    return 0;
}
