//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#ifndef LIBURING_STUBS_H
#define LIBURING_STUBS_H

// only read below stubs if liburing headers were missing
// stubs are needed to build on systems lacking liburing

#ifdef C_NIO_LIBURING_UNAVAILABLE

#ifdef __linux__

#include <stdbool.h>  // bool
#include <linux/time_types.h> // struct __kernel_timespec

// these are pulled in from liburing.h to allow us to manipulate flags etc
// directly, but we cant take the header as it defines extern c functions.

struct io_uring_sq {
    unsigned *khead;
    unsigned *ktail;
    unsigned *kring_mask;
    unsigned *kring_entries;
    unsigned *kflags;
    unsigned *kdropped;
    unsigned *array;
    struct io_uring_sqe *sqes;

    unsigned sqe_head;
    unsigned sqe_tail;

    size_t ring_sz;
    void *ring_ptr;

    unsigned pad[4];
};

struct io_uring_cq {
    unsigned *khead;
    unsigned *ktail;
    unsigned *kring_mask;
    unsigned *kring_entries;
    unsigned *kflags;
    unsigned *koverflow;
    struct io_uring_cqe *cqes;

    size_t ring_sz;
    void *ring_ptr;

    unsigned pad[4];
};

struct io_uring {
    struct io_uring_sq sq;
    struct io_uring_cq cq;
    unsigned flags;
    int ring_fd;

    unsigned features;
    unsigned pad[3];
};

struct statx {}; // FIXME: should include proper header instead, man page include doesnt work as expected, need investigation
struct open_how {}; // FIXME: should include proper header instead, but doesnt seem to exist on older distros

static inline int io_uring_opcode_supported(const struct io_uring_probe *p, int op) { return 0; }
static inline void io_uring_cq_advance(struct io_uring *ring, unsigned nr) { return; }
static inline void io_uring_cqe_seen(struct io_uring *ring, struct io_uring_cqe *cqe) { return; }
static inline void io_uring_sqe_set_data(struct io_uring_sqe *sqe, void *data) { return; }
static inline void *io_uring_cqe_get_data(const struct io_uring_cqe *cqe) { return NULL; }
static inline void io_uring_sqe_set_flags(struct io_uring_sqe *sqe, unsigned flags) { return; }
static inline void io_uring_prep_rw(int op, struct io_uring_sqe *sqe, int fd,
                    const void *addr, unsigned len, __u64 offset) { return; }
static inline void io_uring_prep_splice(struct io_uring_sqe *sqe,
                    int fd_in, int64_t off_in, int fd_out, int64_t off_out,
                    unsigned int nbytes, unsigned int splice_flags) { return; }
static inline void io_uring_prep_tee(struct io_uring_sqe *sqe,
                     int fd_in, int fd_out, unsigned int nbytes,
                                     unsigned int splice_flags) { return ; }
static inline void io_uring_prep_readv(struct io_uring_sqe *sqe, int fd,
                       const struct iovec *iovecs,
                                       unsigned nr_vecs, off_t offset) { return; }
static inline void io_uring_prep_read_fixed(struct io_uring_sqe *sqe, int fd,
                        void *buf, unsigned nbytes,
                                            off_t offset, int buf_index) { return; }
static inline void io_uring_prep_writev(struct io_uring_sqe *sqe, int fd,
                    const struct iovec *iovecs,
                                        unsigned nr_vecs, off_t offset) { return; }
static inline void io_uring_prep_write_fixed(struct io_uring_sqe *sqe, int fd,
                         const void *buf, unsigned nbytes,
                                             off_t offset, int buf_index) { return; }
static inline void io_uring_prep_recvmsg(struct io_uring_sqe *sqe, int fd,
                                         struct msghdr *msg, unsigned flags) { return; }
static inline void io_uring_prep_sendmsg(struct io_uring_sqe *sqe, int fd,
                                         const struct msghdr *msg, unsigned flags) { return; }
static inline void io_uring_prep_poll_add(struct io_uring_sqe *sqe, int fd,
                                          unsigned poll_mask) { return; }
static inline void io_uring_prep_poll_remove(struct io_uring_sqe *sqe,
                                             void *user_data) { return; }
static inline void io_uring_prep_fsync(struct io_uring_sqe *sqe, int fd,
                                       unsigned fsync_flags) { return; }
static inline void io_uring_prep_nop(struct io_uring_sqe *sqe) { return; }
static inline void io_uring_prep_timeout(struct io_uring_sqe *sqe,
                     struct __kernel_timespec *ts,
                                         unsigned count, unsigned flags) { return; }
static inline void io_uring_prep_timeout_remove(struct io_uring_sqe *sqe,
                                                __u64 user_data, unsigned flags) { return; }
static inline void io_uring_prep_timeout_update(struct io_uring_sqe *sqe,
                        struct __kernel_timespec *ts,
                                                __u64 user_data, unsigned flags) { return; }
static inline void io_uring_prep_accept(struct io_uring_sqe *sqe, int fd,
                    struct sockaddr *addr,
                                        socklen_t *addrlen, int flags) { return; }
static inline void io_uring_prep_cancel(struct io_uring_sqe *sqe, void *user_data,
                                        int flags) {return; }
static inline void io_uring_prep_link_timeout(struct io_uring_sqe *sqe,
                          struct __kernel_timespec *ts,
                                              unsigned flags) { return; }
static inline void io_uring_prep_connect(struct io_uring_sqe *sqe, int fd,
                     const struct sockaddr *addr,
                                         socklen_t addrlen) { return; }
static inline void io_uring_prep_files_update(struct io_uring_sqe *sqe,
                          int *fds, unsigned nr_fds,
                                              int offset) { return; }
static inline void io_uring_prep_fallocate(struct io_uring_sqe *sqe, int fd,
                                           int mode, off_t offset, off_t len) { return; }
static inline void io_uring_prep_openat(struct io_uring_sqe *sqe, int dfd,
                                        const char *path, int flags, mode_t mode) { return; }
static inline void io_uring_prep_close(struct io_uring_sqe *sqe, int fd) { return; }
static inline void io_uring_prep_read(struct io_uring_sqe *sqe, int fd,
                                      void *buf, unsigned nbytes, off_t offset) { return; }
static inline void io_uring_prep_write(struct io_uring_sqe *sqe, int fd,
                                       const void *buf, unsigned nbytes, off_t offset) { return; }
static inline void io_uring_prep_statx(struct io_uring_sqe *sqe, int dfd,
                const char *path, int flags, unsigned mask,
                                       struct statx *statxbuf) { return ; }
static inline void io_uring_prep_fadvise(struct io_uring_sqe *sqe, int fd,
                                         off_t offset, off_t len, int advice) { return; }
static inline void io_uring_prep_madvise(struct io_uring_sqe *sqe, void *addr,
                                         off_t length, int advice) { return; }
static inline void io_uring_prep_send(struct io_uring_sqe *sqe, int sockfd,
                                      const void *buf, size_t len, int flags) { return; }
static inline void io_uring_prep_recv(struct io_uring_sqe *sqe, int sockfd,
                                      void *buf, size_t len, int flags) { return; }
static inline void io_uring_prep_openat2(struct io_uring_sqe *sqe, int dfd,
                                         const char *path, struct open_how *how) { return; }
static inline void io_uring_prep_epoll_ctl(struct io_uring_sqe *sqe, int epfd,
                       int fd, int op, struct epoll_event *ev) { return; }
static inline void io_uring_prep_provide_buffers(struct io_uring_sqe *sqe,
                         void *addr, int len, int nr,
                                                 int bgid, int bid) { return; }
static inline void io_uring_prep_remove_buffers(struct io_uring_sqe *sqe,
                                                int nr, int bgid) { return; }
static inline void io_uring_prep_shutdown(struct io_uring_sqe *sqe, int fd,
                                          int how) { return; }
static inline void io_uring_prep_unlinkat(struct io_uring_sqe *sqe, int dfd,
                                          const char *path, int flags) { return; }
static inline void io_uring_prep_renameat(struct io_uring_sqe *sqe, int olddfd,
                      const char *oldpath, int newdfd,
                                          const char *newpath, int flags) { return; }
static inline void io_uring_prep_sync_file_range(struct io_uring_sqe *sqe,
                         int fd, unsigned len,
                                                 off_t offset, int flags) { return; }
static inline unsigned io_uring_sq_ready(const struct io_uring *ring) { return 0; }
static inline unsigned io_uring_sq_space_left(const struct io_uring *ring) { return 0; }
static inline int io_uring_sqring_wait(struct io_uring *ring) { return 0; }
static inline unsigned io_uring_cq_ready(const struct io_uring *ring) { return 0; }
static inline bool io_uring_cq_eventfd_enabled(const struct io_uring *ring) { return false; }
static inline int io_uring_cq_eventfd_toggle(struct io_uring *ring,
                                             bool enabled) { return 0; }
static inline int io_uring_wait_cqe_nr(struct io_uring *ring,
                      struct io_uring_cqe **cqe_ptr,
                                       unsigned wait_nr) { return 0; }
static inline int io_uring_peek_cqe(struct io_uring *ring,
                                    struct io_uring_cqe **cqe_ptr) { return 0; }
static inline int io_uring_wait_cqe(struct io_uring *ring,
                                    struct io_uring_cqe **cqe_ptr) { return 0; }

#endif /* C_NIO_LIBURING_UNAVAILABLE */

#endif /* __linux__ */

#endif /* LIBURING_STUBS_H */
