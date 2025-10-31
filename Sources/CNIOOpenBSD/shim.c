//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2025 Apple Inc. and the SwiftNIO project authors
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
void CNIOOpenBSD_i_do_nothing_just_working_around_a_darwin_toolchain_bug(void) {}

#if defined(__OpenBSD__)

#include <CNIOOpenBSD.h>
#include <pthread.h>
#include <assert.h>
#include <unistd.h>

int CNIOOpenBSD_pthread_set_name_np(pthread_t thread, const char *name) {
    pthread_set_name_np(thread, name);
    return 0;
}

int CNIOOpenBSD_pthread_get_name_np(pthread_t thread, char *name, size_t len) {
    pthread_get_name_np(thread, name, len);
    return 0;
}

int CNIOOpenBSD_sendmmsg(int sockfd, CNIOOpenBSD_mmsghdr *msgvec, unsigned int vlen, int flags) {
    // This is technically undefined behaviour, but it's basically fine because these types are the same size, and we
    // don't think the compiler is inclined to blow anything up here.
    // This comment is from CNIOLinux, but I haven't reverified this applies for OpenBSD.
    return sendmmsg(sockfd, (struct mmsghdr *)msgvec, vlen, flags);
}

int CNIOOpenBSD_recvmmsg(int sockfd, CNIOOpenBSD_mmsghdr *msgvec, unsigned int vlen, int flags, struct timespec *timeout) {
    // This is technically undefined behaviour, but it's basically fine because these types are the same size, and we
    // don't think the compiler is inclined to blow anything up here.
    // This comment is from CNIOLinux, but I haven't reverified this applies for OpenBSD.
    return recvmmsg(sockfd, (struct mmsghdr *)msgvec, vlen, flags, timeout);
}

int CNIOOpenBSD_accept4(int sockfd, struct sockaddr *addr, socklen_t *addrlen, int flags) {
    return accept4(sockfd, addr, addrlen, flags);
}

struct cmsghdr *CNIOOpenBSD_CMSG_FIRSTHDR(const struct msghdr *mhdr) {
    assert(mhdr != NULL);
    return CMSG_FIRSTHDR(mhdr);
}

struct cmsghdr *CNIOOpenBSD_CMSG_NXTHDR(struct msghdr *mhdr, struct cmsghdr *cmsg) {
    assert(mhdr != NULL);
    assert(cmsg != NULL);
    return CMSG_NXTHDR(mhdr, cmsg);
}

const void *CNIOOpenBSD_CMSG_DATA(const struct cmsghdr *cmsg) {
    assert(cmsg != NULL);
    return CMSG_DATA(cmsg);
}

void *CNIOOpenBSD_CMSG_DATA_MUTABLE(struct cmsghdr *cmsg) {
    assert(cmsg != NULL);
    return CMSG_DATA(cmsg);
}

size_t CNIOOpenBSD_CMSG_LEN(size_t payloadSizeBytes) {
    return CMSG_LEN(payloadSizeBytes);
}

size_t CNIOOpenBSD_CMSG_SPACE(size_t payloadSizeBytes) {
    return CMSG_SPACE(payloadSizeBytes);
}

const int CNIOOpenBSD_SO_TIMESTAMP = SO_TIMESTAMP;
const int CNIOOpenBSD_SO_RCVTIMEO = SO_RCVTIMEO;

bool supports_udp_sockopt(int opt, int value) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd == -1) {
        return false;
    }
    int rc = setsockopt(fd, IPPROTO_UDP, opt, &value, sizeof(value));
    close(fd);
    return rc == 0;
}

bool CNIOOpenBSD_supports_udp_segment() {
    #ifndef UDP_SEGMENT
    return false;
    #else
    return supports_udp_sockopt(UDP_SEGMENT, 512);
    #endif
}

bool CNIOOpenBSD_supports_udp_gro() {
    #ifndef UDP_GRO
    return false;
    #else
    return supports_udp_sockopt(UDP_GRO, 1);
    #endif
}

int CNIOOpenBSD_system_info(struct utsname* uname_data) {
    return uname(uname_data);
}

const char* CNIOOpenBSD_dirent_dname(struct dirent* ent) {
    return ent->d_name;
}

const unsigned long CNIOOpenBSD_UTIME_OMIT = UTIME_OMIT;
const unsigned long CNIOOpenBSD_UTIME_NOW = UTIME_NOW;

#ifdef UDP_MAX_SEGMENTS
const long CNIOOpenBSD_UDP_MAX_SEGMENTS = UDP_MAX_SEGMENTS;
#endif
const long CNIOOpenBSD_UDP_MAX_SEGMENTS = -1;

FTS *CNIOOpenBSD_fts_open(char * const *path_argv, int options, int (*compar)(const FTSENT **, const FTSENT **)) {
    return fts_open(path_argv, options, compar);
}
#endif
