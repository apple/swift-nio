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
#ifndef C_NIO_FREEBSD_H
#define C_NIO_FREEBSD_H

#ifdef __FreeBSD__
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <time.h>
#include <dirent.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fts.h>
#include <net/if_dl.h>

extern const int CNIOFreeBSD_AT_EMPTY_PATH;

extern const int CNIOFreeBSD_IPTOS_ECN_NOTECT;
extern const int CNIOFreeBSD_IPTOS_ECN_MASK;
extern const int CNIOFreeBSD_IPTOS_ECN_ECT0;
extern const int CNIOFreeBSD_IPTOS_ECN_ECT1;
extern const int CNIOFreeBSD_IPTOS_ECN_CE;
extern const int CNIOFreeBSD_IPV6_RECVPKTINFO;
extern const int CNIOFreeBSD_IPV6_PKTINFO;

int CNIOFreeBSD_sendmmsg(int sockfd, struct mmsghdr *msgvec, unsigned int vlen, int flags);
int CNIOFreeBSD_recvmmsg(int sockfd, struct mmsghdr *msgvec, unsigned int vlen, int flags, struct timespec *timeout);

// cmsghdr handling
struct cmsghdr *CNIOFreeBSD_CMSG_FIRSTHDR(const struct msghdr *);
struct cmsghdr *CNIOFreeBSD_CMSG_NXTHDR(const struct msghdr *, const struct cmsghdr *);
const void *CNIOFreeBSD_CMSG_DATA(const struct cmsghdr *);
void *CNIOFreeBSD_CMSG_DATA_MUTABLE(struct cmsghdr *);
size_t CNIOFreeBSD_CMSG_LEN(size_t);
size_t CNIOFreeBSD_CMSG_SPACE(size_t);

const char* CNIOFreeBSD_dirent_dname(struct dirent* ent);

#endif  // __FreeBSD__
#endif  // C_NIO_FREEBSD_H
