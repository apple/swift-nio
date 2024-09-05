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
#ifdef __APPLE__
#include <CNIODarwin.h>
#include <err.h>
#include <sysexits.h>
#include <stdlib.h>
#include <limits.h>
#include <errno.h>
#include <assert.h>
#include <netinet/ip.h>
#include <netinet/in.h>
#include "dirent.h"

int CNIODarwin_sendmmsg(int sockfd, CNIODarwin_mmsghdr *msgvec, unsigned int vlen, int flags) {
    // Some quick error checking. If vlen can't fit into int, we bail.
    if ((vlen > INT_MAX) || (msgvec == NULL)) {
        errno = EINVAL;
        return -1;
    }

    for (unsigned int i = 0; i < vlen; i++) {
        ssize_t sendAmount = sendmsg(sockfd, &(msgvec[i].msg_hdr), flags);
        if (sendAmount < 0 && i == 0) {
            // Error on the first send, return the error.
            return -1;
        }

        if (sendAmount < 0) {
            // Error on a later send, return short.
            return i;
        }

        // Send succeeded, save off the bytes written.
        msgvec[i].msg_len = (unsigned int)sendAmount;
    }

    // If we dropped out, we sent everything.
    return vlen;
}

int CNIODarwin_recvmmsg(int sockfd, CNIODarwin_mmsghdr *msgvec, unsigned int vlen, int flags, struct timespec *timeout) {
    errx(EX_SOFTWARE, "recvmmsg shim not implemented on Darwin platforms\n");
}

struct cmsghdr *CNIODarwin_CMSG_FIRSTHDR(const struct msghdr *mhdr) {
    assert(mhdr != NULL);
    return CMSG_FIRSTHDR(mhdr);
}

struct cmsghdr *CNIODarwin_CMSG_NXTHDR(const struct msghdr *mhdr, const struct cmsghdr *cmsg) {
    assert(mhdr != NULL);
    assert(cmsg != NULL);   // Not required by Darwin but Linux needs this so we should match.
    return CMSG_NXTHDR(mhdr, cmsg);
}

const void *CNIODarwin_CMSG_DATA(const struct cmsghdr *cmsg) {
    assert(cmsg != NULL);
    return CMSG_DATA(cmsg);
}

void *CNIODarwin_CMSG_DATA_MUTABLE(struct cmsghdr *cmsg) {
    assert(cmsg != NULL);
    return CMSG_DATA(cmsg);
}

size_t CNIODarwin_CMSG_LEN(size_t payloadSizeBytes) {
    return CMSG_LEN(payloadSizeBytes);
}

size_t CNIODarwin_CMSG_SPACE(size_t payloadSizeBytes) {
    return CMSG_SPACE(payloadSizeBytes);
}

const int CNIODarwin_IPTOS_ECN_NOTECT = IPTOS_ECN_NOTECT;
const int CNIODarwin_IPTOS_ECN_MASK = IPTOS_ECN_MASK;
const int CNIODarwin_IPTOS_ECN_ECT0 = IPTOS_ECN_ECT0;
const int CNIODarwin_IPTOS_ECN_ECT1 = IPTOS_ECN_ECT1;
const int CNIODarwin_IPTOS_ECN_CE = IPTOS_ECN_CE;
const int CNIODarwin_IPV6_RECVPKTINFO = IPV6_RECVPKTINFO;
const int CNIODarwin_IPV6_PKTINFO = IPV6_PKTINFO;

const unsigned long CNIODarwin_IOCTL_VM_SOCKETS_GET_LOCAL_CID = IOCTL_VM_SOCKETS_GET_LOCAL_CID;

const char* CNIODarwin_dirent_dname(struct dirent* ent) {
    return ent->d_name;
}

#endif  // __APPLE__
