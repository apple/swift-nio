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
#ifdef __linux__

#define _GNU_SOURCE
#include <c_nio_linux.h>
#include <pthread.h>

_Static_assert(sizeof(CNIOLinux_mmsghdr) == sizeof(struct mmsghdr),
               "sizes of CNIOLinux_mmsghdr and struct mmsghdr differ");

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

int CNIOLinux_pthread_setname_np(pthread_t thread, const char *name) {
    return pthread_setname_np(thread, name);
}

int CNIOLinux_pthread_getname_np(pthread_t thread, char *name, size_t len) {
    return pthread_getname_np(thread, name, len);
}
#endif
