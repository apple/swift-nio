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

#ifndef LIBURING_NIO_H
#define LIBURING_NIO_H

#ifdef __linux__

// io_uring interface (using liburing)

// Initial setup, dynamically load liburing and resolve symbols.
// Should be called once before using io_uring.
// Return 0 if liburing is succesfully loaded and all required symbols are
// resolved successfully, otherwise returns -1
int CNIOLinux_io_uring_load();

// After a successful CNIOLinux_io_uring_load the below functions may be used
// We expose more functionality from liburing than what is currently used
// by SwiftNIO to make it easier to expand the usage in the future if desired.
// These functions are fundamentally the same as exposed by liburing
// so please refer to any documentation there.
// https://unixism.net/loti/ is also decent, if not comprehensive.

struct io_uring_probe *CNIOLinux_io_uring_get_probe_ring(struct io_uring *ring);
struct io_uring_probe *CNIOLinux_io_uring_get_probe(void);

void CNIOLinux_io_uring_free_probe(struct io_uring_probe *probe);

int CNIOLinux_io_uring_queue_init_params(unsigned entries, struct io_uring *ring,
    struct io_uring_params *p);
int CNIOLinux_io_uring_queue_init(unsigned entries, struct io_uring *ring,
    unsigned flags);
int CNIOLinux_io_uring_queue_mmap(int fd, struct io_uring_params *p,
    struct io_uring *ring);
int CNIOLinux_io_uring_ring_dontfork(struct io_uring *ring);
void CNIOLinux_io_uring_queue_exit(struct io_uring *ring);
unsigned CNIOLinux_io_uring_peek_batch_cqe(struct io_uring *ring,
    struct io_uring_cqe **cqes, unsigned count);
int CNIOLinux_io_uring_wait_cqes(struct io_uring *ring,
    struct io_uring_cqe **cqe_ptr, unsigned wait_nr,
    struct __kernel_timespec *ts, sigset_t *sigmask);
int CNIOLinux_io_uring_wait_cqe_timeout(struct io_uring *ring,
    struct io_uring_cqe **cqe_ptr, struct __kernel_timespec *ts);
int CNIOLinux_io_uring_submit(struct io_uring *ring);
int CNIOLinux_io_uring_submit_and_wait(struct io_uring *ring, unsigned wait_nr);
struct io_uring_sqe *CNIOLinux_io_uring_get_sqe(struct io_uring *ring);

int CNIOLinux_io_uring_register_buffers(struct io_uring *ring,
                    const struct iovec *iovecs,
                    unsigned nr_iovecs);
int CNIOLinux_io_uring_unregister_buffers(struct io_uring *ring);
int CNIOLinux_io_uring_register_files(struct io_uring *ring, const int *files,
                    unsigned nr_files);
int CNIOLinux_io_uring_unregister_files(struct io_uring *ring);
int CNIOLinux_io_uring_register_files_update(struct io_uring *ring, unsigned off,
                    int *files, unsigned nr_files);
int CNIOLinux_io_uring_register_eventfd(struct io_uring *ring, int fd);
int CNIOLinux_io_uring_register_eventfd_async(struct io_uring *ring, int fd);
int CNIOLinux_io_uring_unregister_eventfd(struct io_uring *ring);
int CNIOLinux_io_uring_register_probe(struct io_uring *ring,
                    struct io_uring_probe *p, unsigned nr);
int CNIOLinux_io_uring_register_personality(struct io_uring *ring);
int CNIOLinux_io_uring_unregister_personality(struct io_uring *ring, int id);
int CNIOLinux_io_uring_register_restrictions(struct io_uring *ring,
                      struct io_uring_restriction *res,
                      unsigned int nr_res);
int CNIOLinux_io_uring_enable_rings(struct io_uring *ring);
int CNIOLinux___io_uring_sqring_wait(struct io_uring *ring);
int CNIOLinux___io_uring_get_cqe(struct io_uring *ring,
                  struct io_uring_cqe **cqe_ptr, unsigned submit,
                  unsigned wait_nr, sigset_t *sigmask);

// The rest are inlined functions which reference some of the symbols
// we are dynamically loading, most inlines in liburing just manipulate
// struct members which are fine to call directly, but these we
// don't want to pull in directly.
int CNIOLinux_io_uring_wait_cqe(struct io_uring *ring, struct io_uring_cqe **cqe_ptr);
unsigned CNIOLinux_io_uring_sq_ready(const struct io_uring *ring);
int CNIOLinux_io_uring_opcode_supported(const struct io_uring_probe *p, int op);

// Extra interfaces
unsigned int CNIOLinux_io_uring_ring_size(); // return ring size to use
unsigned int CNIOLinux_io_uring_use_multishot_poll(); // true if we should use multishot poll/updates
void CNIOLinux_io_uring_set_link_flag(struct io_uring_sqe *sqe); // set IOSQE_IO_LINK

#endif /* __linux__ */

#endif /* LIBURING_NIO_H */
