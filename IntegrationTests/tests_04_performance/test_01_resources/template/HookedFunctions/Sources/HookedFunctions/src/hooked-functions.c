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

#define _GNU_SOURCE
#include <atomic-counter.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <hooked-functions.h>
#include <inttypes.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

/* a big block of memory that we'll use for recursive mallocs */
static char g_recursive_malloc_mem[10 * 1024 * 1024] = {0};
/* the index of the first free byte */
static _Atomic ptrdiff_t g_recursive_malloc_next_free_ptr = ATOMIC_VAR_INIT(0);

#define DYLD_INTERPOSE(_replacement,_replacee) \
   __attribute__((used)) static struct { const void *replacement; const void *replacee; } _interpose_##_replacee \
            __attribute__ ((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee };
#define LIBC_SYMBOL(_fun) "" # _fun

static __thread bool g_in_malloc = false;
static __thread bool g_in_realloc = false;
static __thread bool g_in_free = false;
static __thread void *(*g_libc_malloc)(size_t) = NULL;
static __thread void *(*g_libc_realloc)(void *, size_t) = NULL;
static __thread void (*g_libc_free)(void *) = NULL;

// this is called if malloc is called whilst trying to resolve libc's realloc.
// we just vend out pointers to a large block in the BSS (which we never free).
// This block should be large enough because it's only used when malloc is
// called from dlsym which should only happen once per thread.
static void *recursive_malloc(size_t size_in) {
    size_t size = size_in;
    if ((size & 0xf) != 0) {
        // make size 16 byte aligned
        size = (size + 0xf) & (~(size_t)0xf);
    }

    ptrdiff_t next = atomic_fetch_add_explicit(&g_recursive_malloc_next_free_ptr,
                                               size,
                                               memory_order_relaxed);
    if ((size_t)next >= sizeof(g_recursive_malloc_mem)) {
        // we ran out of memory
        return NULL;
    }
    return (void *)((intptr_t)g_recursive_malloc_mem + next);
}

static bool is_recursive_malloc_block(void *ptr) {
    uintptr_t block_begin = (uintptr_t)g_recursive_malloc_mem;
    uintptr_t block_end = block_begin + sizeof(g_recursive_malloc_mem);
    uintptr_t user_ptr = (uintptr_t)ptr;

    return user_ptr >= block_begin && user_ptr < block_end;
}

// this is called if realloc is called whilst trying to resolve libc's realloc.
static void *recursive_realloc(void *ptr, size_t size) {
    // not implemented yet...
    abort();
}

// this is called if free is called whilst trying to resolve libc's free.
static void recursive_free(void *ptr) {
    // not implemented yet...
    abort();
}

#if __APPLE__

/* on Darwin calling the original function is super easy, just call it, done. */
#define JUMP_INTO_LIBC_FUN(_fun, ...) /* \
*/ do { /* \
*/     return _fun(__VA_ARGS__); /* \
*/ } while(0)

#else

/* on other UNIX systems this is slightly harder. Basically we see if we already
 * have a thread local variable that is a pointer to the original libc function.
 * If yes, easy, call it. If no, we need to resolve it which we do by using
 * dlsym. There's only one slight problem: dlsym might call back into the
 * function we're just trying to resolve (it does call malloc). In that case
 * we need to emulate that function (named recursive_*). But that's all then.
 */
#define JUMP_INTO_LIBC_FUN(_fun, ...) /* \
*/ do { /* \
*/     if (!g_libc_ ## _fun) { /* \
*/         if (!g_in_ ## _fun) { /* \
*/             g_in_ ## _fun = true; /* \
*/             g_libc_ ## _fun = dlsym(RTLD_NEXT, LIBC_SYMBOL(_fun)); /* \
*/         } else { /* \
*/             return recursive_ ## _fun (__VA_ARGS__); /* \
*/         } /* \
*/     } /*
*/     g_in_ ## _fun = false; /* \
*/     return g_libc_ ## _fun (__VA_ARGS__); /*
*/ } while(0)

#endif

void replacement_free(void *ptr) {
    if (ptr) {
        inc_free_counter();
        if (!is_recursive_malloc_block(ptr)) {
            JUMP_INTO_LIBC_FUN(free, ptr);
        }
    }
}

void *replacement_malloc(size_t size) {
    inc_malloc_counter();

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

    JUMP_INTO_LIBC_FUN(realloc, ptr, size);
}

void *replacement_calloc(size_t count, size_t size) {
    void *ptr = replacement_malloc(count * size);
    memset(ptr, 0, count * size);
    return ptr;
}

#if __APPLE__
DYLD_INTERPOSE(replacement_free, free)
DYLD_INTERPOSE(replacement_malloc, malloc)
DYLD_INTERPOSE(replacement_realloc, realloc)
DYLD_INTERPOSE(replacement_calloc, calloc)
#endif
