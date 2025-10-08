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
#ifdef __FreeBSD__
#include <CNIOFreeBSD.h>
#include <err.h>
#include <sysexits.h>
#include <stdlib.h>
#include <limits.h>
#include <errno.h>
#include <fcntl.h>
#include <assert.h>
#include <arpa/inet.h>
#include <netinet/ip.h>
#include <netinet/in.h>
#include <sys/uio.h>
#include "dirent.h"

int CNIOFreeBSD_sendmmsg(int sockfd, struct mmsghdr *msgvec, unsigned int vlen, int flags) {
    return sendmmsg(sockfd, msgvec, vlen, flags);
}

int CNIOFreeBSD_recvmmsg(int sockfd, struct mmsghdr *msgvec, unsigned int vlen, int flags, struct timespec *timeout) {
    return recvmmsg(sockfd, msgvec, vlen, flags, timeout);
}

struct cmsghdr *CNIOFreeBSD_CMSG_FIRSTHDR(const struct msghdr *mhdr) {
    assert(mhdr != NULL);
    return CMSG_FIRSTHDR(mhdr);
}

struct cmsghdr *CNIOFreeBSD_CMSG_NXTHDR(const struct msghdr *mhdr, const struct cmsghdr *cmsg) {
    assert(mhdr != NULL);
    assert(cmsg != NULL);   // Not required by Darwin but Linux needs this so we should match.
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

const int CNIOFreeBSD_IPTOS_ECN_NOTECT = IPTOS_ECN_NOTECT;
const int CNIOFreeBSD_IPTOS_ECN_MASK = IPTOS_ECN_MASK;
const int CNIOFreeBSD_IPTOS_ECN_ECT0 = IPTOS_ECN_ECT0;
const int CNIOFreeBSD_IPTOS_ECN_ECT1 = IPTOS_ECN_ECT1;
const int CNIOFreeBSD_IPTOS_ECN_CE = IPTOS_ECN_CE;
const int CNIOFreeBSD_IPV6_RECVPKTINFO = IPV6_RECVPKTINFO;
const int CNIOFreeBSD_IPV6_PKTINFO = IPV6_PKTINFO;
const int CNIOFreeBSD_AT_EMPTY_PATH = AT_EMPTY_PATH;

const char* CNIOFreeBSD_dirent_dname(struct dirent* ent) {
    return ent->d_name;
}

#endif  // __APPLE__
