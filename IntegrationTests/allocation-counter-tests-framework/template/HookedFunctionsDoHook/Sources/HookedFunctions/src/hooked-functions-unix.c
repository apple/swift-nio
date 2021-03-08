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

#ifndef __APPLE__

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

#include <atomic-counter.h>
#include <hooked-functions.h>

/* a big block of memory that we'll use for recursive mallocs */
static char g_recursive_malloc_mem[10 * 1024 * 1024] = {0};
/* the index of the first free byte */
static _Atomic ptrdiff_t g_recursive_malloc_next_free_ptr = ATOMIC_VAR_INIT(0);

#define LIBC_SYMBOL(_fun) "" # _fun

/* Some thread-local flags we use to check if we're recursively in a hooked function. */
static __thread bool g_in_malloc = false;
static __thread bool g_in_realloc = false;
static __thread bool g_in_free = false;

/* The types of the variables holding the libc function pointers. */
typedef void *(*type_libc_malloc)(size_t);
typedef void *(*type_libc_realloc)(void *, size_t);
typedef void  (*type_libc_free)(void *);

/* The (atomic) globals holding the pointer to the original libc implementation. */
_Atomic type_libc_malloc g_libc_malloc;
_Atomic type_libc_realloc g_libc_realloc;
_Atomic type_libc_free g_libc_free;

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

/* On Apple platforms getting to the original libc function from a hooked
 * function is easy.  On other UNIX systems this is slightly harder because we
 * have to look up the function with the dynamic linker.  Because that isn't
 * super performant we cache the lookup result in an (atomic) global.
 *
 * Calling into the libc function if we have already cached it is easy, we
 * (atomically) load it and call into it.  If have not yet cached it, we need to
 * resolve it which we do by using dlsym and then write it into the (atomic)
 * global.  There's only one slight problem: dlsym might call back into the
 * function we're just trying to resolve (dlsym does call malloc). In that case
 * we need to emulate that function (named recursive_*). But that's all then.
 */
#define JUMP_INTO_LIBC_FUN(_fun, ...) /* \
*/ do { /* \
*/     /* Let's see if somebody else already resolved that function for us */ /* \
*/     type_libc_ ## _fun local_fun = atomic_load(&g_libc_ ## _fun); /* \
*/     if (!local_fun) { /* \
*/         /* No, we're the first ones to use this function. */ /* \
*/         if (!g_in_ ## _fun) { /* \
*/             g_in_ ## _fun = true; /* \
*/             /* If we're here, we're at least not recursively in ourselves. */ /* \
*/             /* That means we can use dlsym to resolve the libc function. */ /* \
*/             type_libc_ ## _fun desired = dlsym(RTLD_NEXT, LIBC_SYMBOL(_fun)); /* \
*/             if (atomic_compare_exchange_strong(&g_libc_ ## _fun, &local_fun, desired)) { /* \
*/                 /* If we're here, we won the race, so let's use our resolved function.  */ /* \
*/                 local_fun = desired; /* \
*/             } else { /* \
*/                 /* Lost the race, let's load the global again */ /* \
*/                 local_fun = atomic_load(&g_libc_ ## _fun); /* \
*/              } /* \
*/         } else { /* \
*/             /* Okay, we can't jump into libc here and need to use our own version. */ /* \
*/             return recursive_ ## _fun (__VA_ARGS__); /* \
*/         } /* \
*/     } /* \
*/     return local_fun(__VA_ARGS__); /* \
*/ } while(0)

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
    void *ptr = replacement_malloc(count * size);
    memset(ptr, 0, count * size);
    return ptr;
}

void *replacement_reallocf(void *ptr, size_t size) {
    void *new_ptr = replacement_realloc(ptr, size);
    if (!new_ptr) {
        replacement_free(new_ptr);
    }
    return new_ptr;
}

void *replacement_valloc(size_t size) {
    // not aligning correctly (should be PAGE_SIZE) but good enough
    return replacement_malloc(size);
}

int replacement_posix_memalign(void **memptr, size_t alignment, size_t size) {
    // not aligning correctly (should be `alignment`) but good enough
    void *ptr = replacement_malloc(size);
    if (ptr && memptr) {
        *memptr = ptr;
        return 0;
    } else {
        return 1;
    }
}

#endif
