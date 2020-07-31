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
#ifndef C_NIO_DARWIN_H
#define C_NIO_DARWIN_H

#ifdef __APPLE__
#include <sys/socket.h>
#include <time.h>

// Darwin platforms do not have a sendmmsg implementation available to them. This C module
// provides a shim that implements sendmmsg on top of sendmsg. It also provides a shim for
// recvmmsg, but does not actually implement that shim, instantly throwing errors if called.
//
// On Linux sendmmsg will error immediately in many cases if it knows any of the messages
// cannot be sent. This is not something we can easily achieve from userspace on Darwin,
// so instead if we encounter an error on any message but the first we will return "short".

typedef struct {
    struct msghdr msg_hdr;
    unsigned int msg_len;
} CNIODarwin_mmsghdr;

extern int CNIODarwin_IPTOS_ECN_NOTECT;
extern int CNIODarwin_IPTOS_ECN_MASK;
extern int CNIODarwin_IPTOS_ECN_ECT0;
extern int CNIODarwin_IPTOS_ECN_ECT1;
extern int CNIODarwin_IPTOS_ECN_CE;

int CNIODarwin_sendmmsg(int sockfd, CNIODarwin_mmsghdr *msgvec, unsigned int vlen, int flags);
int CNIODarwin_recvmmsg(int sockfd, CNIODarwin_mmsghdr *msgvec, unsigned int vlen, int flags, struct timespec *timeout);

// cmsghdr handling
struct cmsghdr *CNIODarwin_CMSG_FIRSTHDR(const struct msghdr *);
struct cmsghdr *CNIODarwin_CMSG_NXTHDR(const struct msghdr *, const struct cmsghdr *);
const void *CNIODarwin_CMSG_DATA(const struct cmsghdr *);
void *CNIODarwin_CMSG_DATA_MUTABLE(struct cmsghdr *);
size_t CNIODarwin_CMSG_LEN(size_t);
size_t CNIODarwin_CMSG_SPACE(size_t);

#endif  // __APPLE__
#endif  // C_NIO_DARWIN_H
