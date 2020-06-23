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

#if __APPLE__

#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <malloc/malloc.h>

#include <atomic-counter.h>
#include <hooked-functions.h>

#define DYLD_INTERPOSE(_replacement,_replacee) \
   __attribute__((used)) static struct { const void *replacement; const void *replacee; } _interpose_##_replacee \
            __attribute__ ((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee };

/* on Darwin calling the original function is super easy, just call it, done. */
#define JUMP_INTO_LIBC_FUN(_fun, ...) /* \
*/ do { /* \
*/     return _fun(__VA_ARGS__); /* \
*/ } while(0)

void replacement_free(void *ptr) {
    if (ptr) {
        inc_free_counter();
        JUMP_INTO_LIBC_FUN(free, ptr);
    }
}

void *replacement_malloc(size_t size) {
    inc_malloc_counter();
    add_malloc_bytes_counter((intptr_t) size);

    JUMP_INTO_LIBC_FUN(malloc, size);
}

void *replacement_realloc(void *ptr, size_t size) {
    if (0 == size) {
        replacement_free(ptr);
        return NULL;
    }
    if (!ptr) {
        return replacement_malloc(size);
    }
    inc_free_counter();
    inc_malloc_counter();
    add_malloc_bytes_counter((intptr_t) size);

    JUMP_INTO_LIBC_FUN(realloc, ptr, size);
}

void *replacement_calloc(size_t count, size_t size) {
    inc_malloc_counter();
    add_malloc_bytes_counter((intptr_t)(count * size));

    JUMP_INTO_LIBC_FUN(calloc, count, size);
}

void *replacement_malloc_zone_malloc(malloc_zone_t *zone, size_t size) {
    inc_malloc_counter();
    add_malloc_bytes_counter((intptr_t)size);

    JUMP_INTO_LIBC_FUN(malloc_zone_malloc, zone, size);
}

void *replacement_malloc_zone_calloc(malloc_zone_t *zone, size_t num_items, size_t size) {
    inc_malloc_counter();
    add_malloc_bytes_counter((intptr_t)(size * num_items));

    JUMP_INTO_LIBC_FUN(malloc_zone_calloc, zone, num_items, size);
}

void *replacement_malloc_zone_valloc(malloc_zone_t *zone, size_t size) {
    inc_malloc_counter();
    add_malloc_bytes_counter((intptr_t)size);

    JUMP_INTO_LIBC_FUN(malloc_zone_valloc, zone, size);
}

void *replacement_malloc_zone_realloc(malloc_zone_t *zone, void *ptr, size_t size) {
    if (0 == size) {
        replacement_free(ptr);
        return NULL;
    }
    if (!ptr) {
        return replacement_malloc(size);
    }
    inc_free_counter();
    inc_malloc_counter();
    add_malloc_bytes_counter((intptr_t)size);

    JUMP_INTO_LIBC_FUN(realloc, ptr, size);
}

void *replacement_malloc_zone_memalign(malloc_zone_t *zone, size_t alignment, size_t size) {
    inc_malloc_counter();
    add_malloc_bytes_counter((intptr_t)size);

    JUMP_INTO_LIBC_FUN(malloc_zone_memalign, zone, alignment, size);
}

void replacement_malloc_zone_free(malloc_zone_t *zone, void *ptr) {
    inc_free_counter();

    JUMP_INTO_LIBC_FUN(malloc_zone_free, zone, ptr);
}

void *replacement_reallocf(void *ptr, size_t size) {
    void *new_ptr = replacement_realloc(ptr, size);
    if (!new_ptr) {
        replacement_free(new_ptr);
    }
    return new_ptr;
}

void *replacement_valloc(size_t size) {
    inc_malloc_counter();
    add_malloc_bytes_counter((intptr_t)size);

    JUMP_INTO_LIBC_FUN(valloc, size);
}

int replacement_posix_memalign(void **memptr, size_t alignment, size_t size) {
    inc_malloc_counter();
    add_malloc_bytes_counter((intptr_t)size);

    JUMP_INTO_LIBC_FUN(posix_memalign, memptr, alignment, size);
}

DYLD_INTERPOSE(replacement_free, free)
DYLD_INTERPOSE(replacement_malloc, malloc)
DYLD_INTERPOSE(replacement_realloc, realloc)
DYLD_INTERPOSE(replacement_calloc, calloc)
DYLD_INTERPOSE(replacement_reallocf, reallocf)
DYLD_INTERPOSE(replacement_valloc, valloc)
DYLD_INTERPOSE(replacement_posix_memalign, posix_memalign)
DYLD_INTERPOSE(replacement_malloc_zone_malloc, malloc_zone_malloc)
DYLD_INTERPOSE(replacement_malloc_zone_calloc, malloc_zone_calloc)
DYLD_INTERPOSE(replacement_malloc_zone_valloc, malloc_zone_valloc)
DYLD_INTERPOSE(replacement_malloc_zone_realloc, malloc_zone_realloc)
DYLD_INTERPOSE(replacement_malloc_zone_memalign, malloc_zone_memalign)
DYLD_INTERPOSE(replacement_malloc_zone_free, malloc_zone_free)
#endif
