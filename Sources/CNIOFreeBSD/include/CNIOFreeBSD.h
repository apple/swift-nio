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
#ifndef C_NIO_FREEBSD_H
#define C_NIO_FREEBSD_H

#if defined(__FreeBSD__)
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <sys/socket.h>
#include <sys/event.h>
#include <sys/time.h>
#include <sys/uio.h>
#include <limits.h>

const char *CNIOFreeBSD_inet_ntop(int af, const void *src, char *dst, socklen_t size);
int CNIOFreeBSD_inet_pton(int af, const char *src, void *dst);

extern const int CNIOFreeBSD_UIO_MAXIOV;
extern const int CNIOFreeBSD_SHUT_RD;
extern const int CNIOFreeBSD_SHUT_WR;
extern const int CNIOFreeBSD_SHUT_RDWR;

ssize_t CNIOFreeBSD_sendmmsg(int, struct mmsghdr *, unsigned int, int);
ssize_t CNIOFreeBSD_recvmmsg(int, struct mmsghdr *, unsigned int, int, struct timespec *);
int CNIOFreeBSD_kevent(int, const struct kevent *, int, struct kevent *, int, const struct timespec *);
struct cmsghdr *CNIOFreeBSD_CMSG_FIRSTHDR(const struct msghdr *);
struct cmsghdr *CNIOFreeBSD_CMSG_NXTHDR(struct msghdr *, struct cmsghdr *);
const void *CNIOFreeBSD_CMSG_DATA(const struct cmsghdr *);
void *CNIOFreeBSD_CMSG_DATA_MUTABLE(struct cmsghdr *);
size_t CNIOFreeBSD_CMSG_LEN(size_t);
size_t CNIOFreeBSD_CMSG_SPACE(size_t);

#endif

#endif
