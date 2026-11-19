//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

void CNIOFreeBSD_i_do_nothing_just_working_around_a_darwin_toolchain_bug(void) {}

#if defined(__FreeBSD__)
#include "CNIOFreeBSD.h"
#include <assert.h>

const char *CNIOFreeBSD_inet_ntop(int af, const void *src, char *dst, socklen_t size) {
    return inet_ntop(af, src, dst, size);
}

int CNIOFreeBSD_inet_pton(int af, const char *src, void *dst) {
    return inet_pton(af, src, dst);
}

const int CNIOFreeBSD_UIO_MAXIOV = IOV_MAX;
const int CNIOFreeBSD_SHUT_RD = SHUT_RD;
const int CNIOFreeBSD_SHUT_WR = SHUT_WR;
const int CNIOFreeBSD_SHUT_RDWR = SHUT_RDWR;

ssize_t CNIOFreeBSD_sendmmsg(int fd, struct mmsghdr *msgs, unsigned int count, int flags) {
    return sendmmsg(fd, msgs, (size_t)count, flags);
}
ssize_t CNIOFreeBSD_recvmmsg(int fd, struct mmsghdr *msgs, unsigned int count, int flags, struct timespec *timeout) {
    return recvmmsg(fd, msgs, (size_t)count, flags, timeout);
}
int CNIOFreeBSD_kevent(int fd, const struct kevent *changes, int nchanges, struct kevent *events, int nevents, const struct timespec *timeout) {
    return kevent(fd, changes, nchanges, events, nevents, timeout);
}
struct cmsghdr *CNIOFreeBSD_CMSG_FIRSTHDR(const struct msghdr *mhdr) {
    assert(mhdr != NULL);
    return CMSG_FIRSTHDR(mhdr);
}

struct cmsghdr *CNIOFreeBSD_CMSG_NXTHDR(struct msghdr *mhdr, struct cmsghdr *cmsg) {
    assert(mhdr != NULL);
    assert(cmsg != NULL);
    return CMSG_NXTHDR(mhdr, cmsg);
}

const void *CNIOFreeBSD_CMSG_DATA(const struct cmsghdr *cmsg) {
    assert(cmsg != NULL);
    return CMSG_DATA(cmsg);
}

void *CNIOFreeBSD_CMSG_DATA_MUTABLE(struct cmsghdr *cmsg) {
    assert(cmsg != NULL);
    return CMSG_DATA(cmsg);
}

size_t CNIOFreeBSD_CMSG_LEN(size_t payloadSizeBytes) {
    return CMSG_LEN(payloadSizeBytes);
}

size_t CNIOFreeBSD_CMSG_SPACE(size_t payloadSizeBytes) {
    return CMSG_SPACE(payloadSizeBytes);
}

#endif
