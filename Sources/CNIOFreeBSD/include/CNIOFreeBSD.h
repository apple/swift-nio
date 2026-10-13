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
#include <sys/types.h>
#include <arpa/inet.h>
#include <dirent.h>
#include <fts.h>
#include <net/if_dl.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>

const char *CNIOFreeBSD_inet_ntop(int af, const void *src, char *dst, socklen_t size);
int CNIOFreeBSD_inet_pton(int af, const char *src, void *dst);

extern const int CNIOFreeBSD_AT_EMPTY_PATH;

extern const int CNIOFreeBSD_IPTOS_ECN_NOTECT;
extern const int CNIOFreeBSD_IPTOS_ECN_MASK;
extern const int CNIOFreeBSD_IPTOS_ECN_ECT0;
extern const int CNIOFreeBSD_IPTOS_ECN_ECT1;
extern const int CNIOFreeBSD_IPTOS_ECN_CE;
extern const int CNIOFreeBSD_IPV6_RECVPKTINFO;
extern const int CNIOFreeBSD_IPV6_PKTINFO;

extern const int CNIOFreeBSD_TCPS_ESTABLISHED;

int CNIOFreeBSD_sendmmsg(int sockfd, struct mmsghdr *msgvec, unsigned int vlen, int flags);
int CNIOFreeBSD_recvmmsg(int sockfd, struct mmsghdr *msgvec, unsigned int vlen, int flags, struct timespec *timeout);

struct cmsghdr *CNIOFreeBSD_CMSG_FIRSTHDR(const struct msghdr *);
struct cmsghdr *CNIOFreeBSD_CMSG_NXTHDR(const struct msghdr *, const struct cmsghdr *);
const void *CNIOFreeBSD_CMSG_DATA(const struct cmsghdr *);
void *CNIOFreeBSD_CMSG_DATA_MUTABLE(struct cmsghdr *);
size_t CNIOFreeBSD_CMSG_LEN(size_t);
size_t CNIOFreeBSD_CMSG_SPACE(size_t);

const char* CNIOFreeBSD_dirent_dname(struct dirent* ent);

#endif  // __FreeBSD__

#endif  // C_NIO_FREEBSD_H
