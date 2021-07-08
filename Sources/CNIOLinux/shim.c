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

// Xcode's Archive builds with Xcode's Package support struggle with empty .c files
// (https://bugs.swift.org/browse/SR-12939).
void CNIOLinux_i_do_nothing_just_working_around_a_darwin_toolchain_bug(void) {}

#ifdef __linux__

#define _GNU_SOURCE
#include <CNIOLinux.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <sys/prctl.h>
#include <unistd.h>
#include <assert.h>

_Static_assert(sizeof(CNIOLinux_mmsghdr) == sizeof(struct mmsghdr),
               "sizes of CNIOLinux_mmsghdr and struct mmsghdr differ");

_Static_assert(sizeof(CNIOLinux_in6_pktinfo) == sizeof(struct in6_pktinfo),
               "sizes of CNIOLinux_in6_pktinfo and struct in6_pktinfo differ");

int CNIOLinux_sendmmsg(int sockfd, CNIOLinux_mmsghdr *msgvec, unsigned int vlen, int flags) {
    // This is technically undefined behaviour, but it's basically fine because these types are the same size, and we
    // don't think the compiler is inclined to blow anything up here.
    return sendmmsg(sockfd, (struct mmsghdr *)msgvec, vlen, flags);
}

int CNIOLinux_recvmmsg(int sockfd, CNIOLinux_mmsghdr *msgvec, unsigned int vlen, int flags, struct timespec *timeout) {
    // This is technically undefined behaviour, but it's basically fine because these types are the same size, and we
    // don't think the compiler is inclined to blow anything up here.
    return recvmmsg(sockfd, (struct mmsghdr *)msgvec, vlen, flags, timeout);
}

int CNIOLinux_accept4(int sockfd, struct sockaddr *addr, socklen_t *addrlen, int flags) {
    return accept4(sockfd, addr, addrlen, flags);
}

int CNIOLinux_pthread_setname_np(pthread_t thread, const char *name) {
    return pthread_setname_np(thread, name);
}

int CNIOLinux_pthread_getname_np(pthread_t thread, char *name, size_t len) {
#ifdef __ANDROID__
    // https://android.googlesource.com/platform/bionic/+/master/libc/bionic/pthread_setname_np.cpp#51
    if (thread == pthread_self()) {
        return TEMP_FAILURE_RETRY(prctl(PR_GET_NAME, name)) == -1 ? -1 : 0;
    }

    char comm_name[64];
    snprintf(comm_name, sizeof(comm_name), "/proc/self/task/%d/comm", pthread_gettid_np(thread));
    int fd = TEMP_FAILURE_RETRY(open(comm_name, O_CLOEXEC | O_RDONLY));

    if (fd == -1) return -1;

    ssize_t n = TEMP_FAILURE_RETRY(read(fd, name, len));
    close(fd);
    if (n == -1) return -1;

    // The kernel adds a trailing '\n' to the /proc file,
    // so this is actually the normal case for short names.
    if (n > 0 && name[n - 1] == '\n') {
        name[n - 1] = '\0';
        return 0;
    }

    if (n >= 0 && len <= SSIZE_MAX && n == (ssize_t)len) return 1;

    name[n] = '\0';
    return 0;
#else
    return pthread_getname_np(thread, name, len);
#endif
}

int CNIOLinux_pthread_setaffinity_np(pthread_t thread, size_t cpusetsize, const cpu_set_t *cpuset) {
#ifdef __ANDROID__
    return sched_setaffinity(pthread_gettid_np(thread), cpusetsize, cpuset);
#else
    return pthread_setaffinity_np(thread, cpusetsize, cpuset);
#endif
}

int CNIOLinux_pthread_getaffinity_np(pthread_t thread, size_t cpusetsize, cpu_set_t *cpuset) {
#ifdef __ANDROID__
    return sched_getaffinity(pthread_gettid_np(thread), cpusetsize, cpuset);
#else
    return pthread_getaffinity_np(thread, cpusetsize, cpuset);
#endif
}

void CNIOLinux_CPU_SET(int cpu, cpu_set_t *set) {
    CPU_SET(cpu, set);
}

void CNIOLinux_CPU_ZERO(cpu_set_t *set) {
    CPU_ZERO(set);
}

int CNIOLinux_CPU_ISSET(int cpu, cpu_set_t *set) {
    return CPU_ISSET(cpu, set);
}

int CNIOLinux_CPU_SETSIZE() {
    return CPU_SETSIZE;
}

struct cmsghdr *CNIOLinux_CMSG_FIRSTHDR(const struct msghdr *mhdr) {
    assert(mhdr != NULL);
    return CMSG_FIRSTHDR(mhdr);
}

struct cmsghdr *CNIOLinux_CMSG_NXTHDR(struct msghdr *mhdr, struct cmsghdr *cmsg) {
    assert(mhdr != NULL);
    assert(cmsg != NULL);
    return CMSG_NXTHDR(mhdr, cmsg);
}

const void *CNIOLinux_CMSG_DATA(const struct cmsghdr *cmsg) {
    assert(cmsg != NULL);
    return CMSG_DATA(cmsg);
}

void *CNIOLinux_CMSG_DATA_MUTABLE(struct cmsghdr *cmsg) {
    assert(cmsg != NULL);
    return CMSG_DATA(cmsg);
}

size_t CNIOLinux_CMSG_LEN(size_t payloadSizeBytes) {
    return CMSG_LEN(payloadSizeBytes);
}

size_t CNIOLinux_CMSG_SPACE(size_t payloadSizeBytes) {
    return CMSG_SPACE(payloadSizeBytes);
}

const int CNIOLinux_SO_TIMESTAMP = SO_TIMESTAMP;
const int CNIOLinux_SO_RCVTIMEO = SO_RCVTIMEO;
#endif
