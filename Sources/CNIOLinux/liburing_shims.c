//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// Interface to liburing, uses dlopen/dlsym to provide access to the library
// functions to allow running on platforms without liburing. Capturing
// inline functions too at the end (they typically only manipulate structs
// directly and could be used directly using CNIOLinux.xxx, but wrapped here for
// unification and completeness).

// FIXME: Check if this is needed, copied from shim.c to
// avoid possible problems due to:
// Xcode's Archive builds with Xcode's Package support struggle with empty .c files
// (https://bugs.swift.org/browse/SR-12939).
void CNIOLinux_i_do_nothing_just_working_around_a_darwin_toolchain_bug2(void) {}

#ifdef __linux__

#define _GNU_SOURCE
#include <CNIOLinux.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <sys/prctl.h>
#include <unistd.h>
#include <assert.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <errno.h>
#include <ctype.h>
#include <sys/utsname.h>
#include <pthread.h>
#include <string.h>

pthread_once_t uring_once_control = PTHREAD_ONCE_INIT;

// local typedefs for readability of function pointers
// these should exactly match the signatures in liburing.h
typedef struct io_uring_probe *(*io_uring_get_probe_ring_fp)(struct io_uring *ring);
typedef struct io_uring_probe *(*io_uring_get_probe_fp)(void);
typedef void (*io_uring_free_probe_fp)(struct io_uring_probe *probe);
typedef int (*io_uring_queue_init_params_fp)(unsigned entries, struct io_uring *ring,
    struct io_uring_params *p);
typedef int (*io_uring_queue_init_fp)(unsigned entries, struct io_uring *ring,
    unsigned flags);
typedef int (*io_uring_queue_mmap_fp)(int fd, struct io_uring_params *p,
    struct io_uring *ring);
typedef int (*io_uring_ring_dontfork_fp)(struct io_uring *ring);
typedef void (*io_uring_queue_exit_fp)(struct io_uring *ring);
typedef unsigned (*io_uring_peek_batch_cqe_fp)(struct io_uring *ring,
    struct io_uring_cqe **cqes, unsigned count);
typedef int (*io_uring_wait_cqes_fp)(struct io_uring *ring,
    struct io_uring_cqe **cqe_ptr, unsigned wait_nr,
    struct __kernel_timespec *ts, sigset_t *sigmask);
typedef int (*io_uring_wait_cqe_timeout_fp)(struct io_uring *ring,
    struct io_uring_cqe **cqe_ptr, struct __kernel_timespec *ts);
typedef int (*io_uring_submit_fp)(struct io_uring *ring);
typedef int (*io_uring_submit_and_wait_fp)(struct io_uring *ring, unsigned wait_nr);
typedef struct io_uring_sqe *(*io_uring_get_sqe_fp)(struct io_uring *ring);
typedef int (*io_uring_register_buffers_fp)(struct io_uring *ring,
                    const struct iovec *iovecs,
                    unsigned nr_iovecs);
typedef int (*io_uring_unregister_buffers_fp)(struct io_uring *ring);
typedef int (*io_uring_register_files_fp)(struct io_uring *ring, const int *files,
                    unsigned nr_files);
typedef int (*io_uring_unregister_files_fp)(struct io_uring *ring);
typedef int (*io_uring_register_files_update_fp)(struct io_uring *ring, unsigned off,
                    int *files, unsigned nr_files);
typedef int (*io_uring_register_eventfd_fp)(struct io_uring *ring, int fd);
typedef int (*io_uring_register_eventfd_async_fp)(struct io_uring *ring, int fd);
typedef int (*io_uring_unregister_eventfd_fp)(struct io_uring *ring);
typedef int (*io_uring_register_probe_fp)(struct io_uring *ring,
                    struct io_uring_probe *p, unsigned nr);
typedef int (*io_uring_register_personality_fp)(struct io_uring *ring);
typedef int (*io_uring_unregister_personality_fp)(struct io_uring *ring, int id);
typedef int (*io_uring_register_restrictions_fp)(struct io_uring *ring,
                      struct io_uring_restriction *res,
                      unsigned int nr_res);
typedef int (*io_uring_enable_rings_fp)(struct io_uring *ring);
typedef int (*__io_uring_sqring_wait_fp)(struct io_uring *ring);
typedef int (*__io_uring_get_cqe_fp)(struct io_uring *ring,
                  struct io_uring_cqe **cqe_ptr, unsigned submit,
                  unsigned wait_nr, sigset_t *sigmask);

// local static struct holding resolved function pointers from dlsym
static struct _liburing_functions_t
{
    io_uring_get_probe_ring_fp io_uring_get_probe_ring;
    io_uring_get_probe_fp io_uring_get_probe;
    io_uring_free_probe_fp io_uring_free_probe;
    io_uring_queue_init_params_fp io_uring_queue_init_params;
    io_uring_queue_init_fp io_uring_queue_init;
    io_uring_queue_mmap_fp io_uring_queue_mmap;
    io_uring_ring_dontfork_fp io_uring_ring_dontfork;
    io_uring_queue_exit_fp io_uring_queue_exit;
    io_uring_peek_batch_cqe_fp io_uring_peek_batch_cqe;
    io_uring_wait_cqes_fp io_uring_wait_cqes;
    io_uring_wait_cqe_timeout_fp io_uring_wait_cqe_timeout;
    io_uring_submit_fp io_uring_submit;
    io_uring_submit_and_wait_fp io_uring_submit_and_wait;
    io_uring_get_sqe_fp io_uring_get_sqe;
    io_uring_register_buffers_fp io_uring_register_buffers;
    io_uring_unregister_buffers_fp io_uring_unregister_buffers;
    io_uring_register_files_fp io_uring_register_files;
    io_uring_unregister_files_fp io_uring_unregister_files;
    io_uring_register_files_update_fp io_uring_register_files_update;
    io_uring_register_eventfd_fp io_uring_register_eventfd;
    io_uring_register_eventfd_async_fp io_uring_register_eventfd_async;
    io_uring_unregister_eventfd_fp io_uring_unregister_eventfd;
    io_uring_register_probe_fp io_uring_register_probe;
    io_uring_register_personality_fp io_uring_register_personality;
    io_uring_unregister_personality_fp io_uring_unregister_personality;
    __io_uring_sqring_wait_fp __io_uring_sqring_wait;
    __io_uring_get_cqe_fp __io_uring_get_cqe;
} liburing_functions;

// Convenience macro for resolving
#define _DL_RESOLVE(symbol) \
    liburing_functions.symbol = (symbol ## _fp) dlsym(dl_handle, #symbol);  \
    if ((err = dlerror()) != NULL) {  \
        printf("WARNING: Failed to resolve " #symbol " from liburing, falling back on epoll()\n");  \
        (void) dlclose(dl_handle); \
        return -1;  \
    }

// dynamically load liburing and resolve symbols. Should be called once before using io_uring.
// returns 0 on successful loading and resolving of functions, otherwise error

// Definitons from syscall.c in liburing, we'll just do a syscall that will fail
// to check for availability of the interface - better than checking specific kernel
// versions as support can be backported to earlier kernels

#ifdef __alpha__
/*
 * alpha is the only exception, all other architectures
 * have common numbers for new system calls.
 */
# ifndef __NR_io_uring_setup
#  define __NR_io_uring_setup        535
# endif
# ifndef __NR_io_uring_enter
#  define __NR_io_uring_enter        536
# endif
# ifndef __NR_io_uring_register
#  define __NR_io_uring_register    537
# endif
#else /* !__alpha__ */
# ifndef __NR_io_uring_setup
#  define __NR_io_uring_setup        425
# endif
# ifndef __NR_io_uring_enter
#  define __NR_io_uring_enter        426
# endif
# ifndef __NR_io_uring_register
#  define __NR_io_uring_register    427
# endif
#endif

int _check_syscall_available() {
    errno = 0;
    if (syscall(__NR_io_uring_register, 0, IORING_UNREGISTER_BUFFERS, NULL, 0) && errno == ENOSYS) {
        return -1;
    }
    return 0;
}

int _check_capabilities() {
    struct io_uring_probe *probe = CNIOLinux_io_uring_get_probe();
    int capabilities_check;
    
    capabilities_check = CNIOLinux_io_uring_opcode_supported(probe, IORING_OP_POLL_ADD) &
                         CNIOLinux_io_uring_opcode_supported(probe, IORING_OP_POLL_REMOVE);

    CNIOLinux_io_uring_free_probe(probe);
    return capabilities_check == 1 ? 0 : -1;
}

#define SWIFTNIO_URING_DEFAULT_SIZE 4096
#define SWIFTNIO_URING_MIN_SIZE 4
#define SWIFTNIO_URING_MAX_SIZE 65536

unsigned int CNIOLinux_io_uring_ring_size() {
    const char *uring_size = getenv("SWIFTNIO_URING_RING_SIZE");
    int size = 0;

    if (!uring_size)
        return SWIFTNIO_URING_DEFAULT_SIZE;
    
    size = strtol(uring_size, NULL, 0);

    if (size < SWIFTNIO_URING_MIN_SIZE) {
        return SWIFTNIO_URING_MIN_SIZE;
    }

    if (size > SWIFTNIO_URING_MAX_SIZE) {
        return SWIFTNIO_URING_MAX_SIZE;
    }
    
    return size;
}

// whether to use multishot poll / poll updates
unsigned int CNIOLinux_io_uring_use_multishot_poll() {
    return (getenv("SWIFTNIO_URING_USE_NEW_POLL") != NULL)?1:0;
}

int CNIOLinux_io_uring_load()
{
    void *dl_handle;
    const char *err;
    
    // first a number of checks, did we compile with actual liburing headers?
#ifdef C_NIO_LIBURING_UNAVAILABLE
    return -1;
#endif

    // do the kernel have io_uring syscalls?
    if (_check_syscall_available() != 0) {
        fprintf(stderr, "io_uring syscall not available.\n");
        return -1;
    }

    // have we manually enabled liburing?
    if (getenv("SWIFTNIO_URING_ENABLED") == NULL)
    {
        return -1;
    }
    
    // have we explicitly diabled liburing?
    if (getenv("SWIFTNIO_URING_DISABLED") != NULL) // Just an esacpe hatch - allows for easier testing with epoll
    {
        fprintf(stderr, "SWIFTNIO_URING_DISABLED set, disabling liburing.\n");
        return -1;
    }
    
    // then we can finally try to load the library and resolve all symbols
    dlerror(); // canonical way of clearing dlerror
    dl_handle = dlopen("liburing.so", RTLD_LAZY);
    if (((err = dlerror()) != NULL) || !dl_handle) {
        fprintf(stderr, "WARNING: Failed to load liburing.so, using epoll() instead. [%s] [%p]\n", err?err:"Unknown reason", dl_handle);
        return -1;
    }
    
     // try to resolve all symbols we need, macro will fail with -1 if unsuccessful
    _DL_RESOLVE(io_uring_get_probe_ring);
    _DL_RESOLVE(io_uring_get_probe);
    _DL_RESOLVE(io_uring_free_probe);
    _DL_RESOLVE(io_uring_queue_init_params);
    _DL_RESOLVE(io_uring_queue_init);
    _DL_RESOLVE(io_uring_queue_mmap);
    _DL_RESOLVE(io_uring_ring_dontfork);
    _DL_RESOLVE(io_uring_queue_exit);
    _DL_RESOLVE(io_uring_peek_batch_cqe);
    _DL_RESOLVE(io_uring_wait_cqes);
    _DL_RESOLVE(io_uring_wait_cqe_timeout);
    _DL_RESOLVE(io_uring_submit);
    _DL_RESOLVE(io_uring_submit_and_wait);
    _DL_RESOLVE(io_uring_get_sqe);
    _DL_RESOLVE(io_uring_register_buffers);
    _DL_RESOLVE(io_uring_unregister_buffers);
    _DL_RESOLVE(io_uring_register_files);
    _DL_RESOLVE(io_uring_unregister_files);
    _DL_RESOLVE(io_uring_register_files_update);
    _DL_RESOLVE(io_uring_register_eventfd);
    _DL_RESOLVE(io_uring_register_eventfd_async);
    _DL_RESOLVE(io_uring_unregister_eventfd);
    _DL_RESOLVE(io_uring_register_probe);
    _DL_RESOLVE(io_uring_register_personality);
    _DL_RESOLVE(io_uring_unregister_personality);
    _DL_RESOLVE(__io_uring_sqring_wait);
    _DL_RESOLVE(__io_uring_get_cqe);
        
    // Finally after resolving, probe actual capabilities
    if (_check_capabilities() != 0) {
        (void) dlclose(dl_handle); // we don't care about errors, nothing we can do anyway
        return -1;
    }

    return 0;
}

// And the wrappers, should never be called unless we've done CNIOLinux_io_uring_load once first.

pthread_mutex_t global_ring_mutex = PTHREAD_MUTEX_INITIALIZER;
static struct io_uring global_ring; // shared small ring to be able to reuse SQPOLL kernel thread

// FIXME: We need to look at cpu affinity and preferably bind the SQPOLL thread to a specific core
// and support cgroup / cpu sets on Linux to isolate it - then we should set IORING_SETUP_SQ_AFF here.

int CNIOLinux_io_uring_queue_init(unsigned entries, struct io_uring *ring,
    unsigned flags)
{
    if (flags & IORING_SETUP_SQPOLL)
    {
        pthread_mutex_lock(&global_ring_mutex);
        if (!global_ring.ring_fd)
        {
            // setup a small global ring whose fd we can reference to use shared kernel sqpoll thread for all rings
            // we don't particulariy care if we fail, then no SQPOLL shared ring
            (void) liburing_functions.io_uring_queue_init(4, &global_ring, IORING_SETUP_SQPOLL); // should have IORING_SETUP_SQ_AFF
        }
        pthread_mutex_unlock(&global_ring_mutex);

        if (global_ring.ring_fd) // use shared kernel thread if it exists, otherwise fallthrough to normal setup
        {
            struct io_uring_params params;
            memset(&params, 0, sizeof(params));
            params.flags = flags | IORING_SETUP_ATTACH_WQ;
            params.wq_fd = global_ring.ring_fd;
            return CNIOLinux_io_uring_queue_init_params(entries, ring, &params);
        }
    }

    return liburing_functions.io_uring_queue_init( entries, ring, flags);
}

struct io_uring_probe *CNIOLinux_io_uring_get_probe_ring(struct io_uring *ring)
{
    return liburing_functions.io_uring_get_probe_ring(ring);
}

struct io_uring_probe * CNIOLinux_io_uring_get_probe(void)
{
    return liburing_functions.io_uring_get_probe();
}

void CNIOLinux_io_uring_free_probe(struct io_uring_probe *probe)
{
    return liburing_functions.io_uring_free_probe(probe);
}

int CNIOLinux_io_uring_queue_init_params(unsigned entries, struct io_uring *ring,
    struct io_uring_params *p)
{
    return liburing_functions.io_uring_queue_init_params(entries, ring, p);
}

int CNIOLinux_io_uring_queue_mmap(int fd, struct io_uring_params *p,
    struct io_uring *ring)
{
    return liburing_functions.io_uring_queue_mmap(fd, p, ring);
}

int CNIOLinux_io_uring_ring_dontfork(struct io_uring *ring)
{
    return liburing_functions.io_uring_ring_dontfork(ring);
}

void CNIOLinux_io_uring_queue_exit(struct io_uring *ring)
{
    return liburing_functions.io_uring_queue_exit(ring);
}

unsigned CNIOLinux_io_uring_peek_batch_cqe(struct io_uring *ring,
    struct io_uring_cqe **cqes, unsigned count)
{
    return liburing_functions.io_uring_peek_batch_cqe(ring, cqes, count);
}

int CNIOLinux_io_uring_wait_cqes(struct io_uring *ring,
    struct io_uring_cqe **cqe_ptr, unsigned wait_nr,
    struct __kernel_timespec *ts, sigset_t *sigmask)
{
    return liburing_functions.io_uring_wait_cqes(ring, cqe_ptr, wait_nr, ts, sigmask);
}

int CNIOLinux_io_uring_wait_cqe_timeout(struct io_uring *ring,
    struct io_uring_cqe **cqe_ptr, struct __kernel_timespec *ts)
{
    return liburing_functions.io_uring_wait_cqe_timeout(ring, cqe_ptr, ts);
}

int CNIOLinux_io_uring_submit(struct io_uring *ring)
{
    return liburing_functions.io_uring_submit(ring);
}

int CNIOLinux_io_uring_submit_and_wait(struct io_uring *ring, unsigned wait_nr)
{
    return liburing_functions.io_uring_submit_and_wait(ring, wait_nr);
}


// Adopting some retry code from queue.c from liburing with slight
// modifications - we never want to have to handle retries of
// SQE allocation in all places it could possibly occur.
//
// If the SQ ring is full, we may need to submit IO first

struct io_uring_sqe *CNIOLinux_io_uring_get_sqe(struct io_uring *ring)
{
    struct io_uring_sqe *sqe;
    int ret;
    
    // FIXME: io_uring_submit can fail here due to backpressure from kernel
    // for not reaping CQE:s. I think we should consider handling that
    // as a fatalError, as fundamentally the ring size is too small compared
    // to the amount of events the user tries to push through in a single
    // eventloop tick. This is basically a problem for synthetic tests that
    // e.g. do a huge amount of registration modifications.
    while (!(sqe = liburing_functions.io_uring_get_sqe(ring))) {
        ret = CNIOLinux_io_uring_submit(ring);
        assert(ret >= 0);
    }
    
    // FIXME: When adding support for SQPOLL we should probably
    // should use this for waiting inside the loop instead/also
    // static inline int io_uring_sqring_wait(struct io_uring *ring)

    return sqe;
}

int CNIOLinux_io_uring_register_buffers(struct io_uring *ring,
                    const struct iovec *iovecs,
                    unsigned nr_iovecs)
{
    return liburing_functions.io_uring_register_buffers(ring, iovecs, nr_iovecs);
}

int CNIOLinux_io_uring_unregister_buffers(struct io_uring *ring)
{
    return liburing_functions.io_uring_unregister_buffers(ring);
}

int CNIOLinux_io_uring_register_files(struct io_uring *ring, const int *files,
                    unsigned nr_files)
{
    return liburing_functions.io_uring_register_files(ring, files, nr_files);
}

int CNIOLinux_io_uring_unregister_files(struct io_uring *ring)
{
    return liburing_functions.io_uring_unregister_files(ring);
}

int CNIOLinux_io_uring_register_files_update(struct io_uring *ring, unsigned off,
                    int *files, unsigned nr_files)
{
    return liburing_functions.io_uring_register_files_update(ring, off, files, nr_files);
}

int CNIOLinux_io_uring_register_eventfd(struct io_uring *ring, int fd)
{
    return liburing_functions.io_uring_register_eventfd(ring, fd);
}

int CNIOLinux_io_uring_register_eventfd_async(struct io_uring *ring, int fd)
{
    return liburing_functions.io_uring_register_eventfd_async(ring, fd);
}

int CNIOLinux_io_uring_unregister_eventfd(struct io_uring *ring)
{
    return liburing_functions.io_uring_unregister_eventfd(ring);
}

int CNIOLinux_io_uring_register_probe(struct io_uring *ring,
                    struct io_uring_probe *p, unsigned nr)
{
    return liburing_functions.io_uring_register_probe(ring, p, nr);
}

int CNIOLinux_io_uring_register_personality(struct io_uring *ring)
{
    return liburing_functions.io_uring_register_personality(ring);
}

int CNIOLinux_io_uring_unregister_personality(struct io_uring *ring, int id)
{
    return liburing_functions.io_uring_unregister_personality(ring, id);
}

inline int CNIOLinux___io_uring_sqring_wait(struct io_uring *ring)
{
    return liburing_functions.__io_uring_sqring_wait(ring);
}

// Inlined functions that reference dynamically loaded functions
// basically copied from liburing.h with minimal adjustments.

/*
 * Return an IO completion, waiting for 'wait_nr' completions if one isn't
 * readily available. Returns 0 with cqe_ptr filled in on success, -errno on
 * failure.
 */
int CNIOLinux_io_uring_wait_cqe_nr(struct io_uring *ring,
                      struct io_uring_cqe **cqe_ptr,
                      unsigned wait_nr)
{
    return liburing_functions.__io_uring_get_cqe(ring, cqe_ptr, 0, wait_nr, NULL);
}

/*
 * Return an IO completion, if one is readily available. Returns 0 with
 * cqe_ptr filled in on success, -errno on failure.
 */
int CNIOLinux_io_uring_peek_cqe(struct io_uring *ring,
                    struct io_uring_cqe **cqe_ptr)
{
    return CNIOLinux_io_uring_wait_cqe_nr(ring, cqe_ptr, 0);
}

/*
 * Return an IO completion, waiting for it if necessary. Returns 0 with
 * cqe_ptr filled in on success, -errno on failure.
 */
int CNIOLinux_io_uring_wait_cqe(struct io_uring *ring,
                    struct io_uring_cqe **cqe_ptr)
{
    return CNIOLinux_io_uring_wait_cqe_nr(ring, cqe_ptr, 1);
}


/*
 * Returns number of unconsumed (if SQPOLL) or unsubmitted entries exist in
 * the SQ ring
 */
unsigned CNIOLinux_io_uring_sq_ready(const struct io_uring *ring)
{
    return io_uring_sq_ready(ring);
}

int CNIOLinux_io_uring_opcode_supported(const struct io_uring_probe *p, int op)
{
    return io_uring_opcode_supported(p, op);
}

/*inline extern struct io_uring_sqe *CNIOLinux_io_uring_get_sqe(struct io_uring *ring)
{
    return io_uring_get_sqe(ring);
}

inline void CNIOLinux_io_uring_submit(struct io_uring *ring)
{
    io_uring_submit(ring);
    return;
}
*/

void CNIOLinux_io_uring_set_link_flag(struct io_uring_sqe *sqe)
{
    sqe->flags |= IOSQE_IO_LINK;
    return;
}

#endif
