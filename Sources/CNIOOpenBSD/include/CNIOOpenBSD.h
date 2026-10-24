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
#ifndef C_NIO_OPENBSD_H
#define C_NIO_OPENBSD_H

#if defined(__OpenBSD__)
#include <sys/types.h>
#include <sys/event.h>
#include <pthread_np.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <sys/utsname.h>
#include <dirent.h>
#include <fts.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <pthread.h>
#include <stdbool.h>


// Some explanation is required here.
//
// Due to SR-6772, we cannot get Swift code to directly see any of the mmsg structures or
// functions. However, we *can* get C code built by SwiftPM to see them. For this reason we
// elect to provide a selection of shims to enable Swift code to use recv_mmsg and send_mmsg.
// Mostly this is fine, but to minimise the overhead we want the Swift code to be able to
// create the msgvec directly without requiring further memory fussiness in our C shim.
// That requires us to also construct a C structure that has the same layout as struct mmsghdr.
//
// Conveniently glibc has pretty strict ABI stability rules, and this structure is part of the
// glibc ABI, so we can just reproduce the structure definition here and feel confident that it
// will be sufficient.
//
// If SR-6772 ever gets resolved we can remove this shim.
//
// https://bugs.swift.org/browse/SR-6772

typedef struct {
    struct msghdr msg_hdr;
    unsigned int msg_len;
} CNIOOpenBSD_mmsghdr;

typedef struct {
    struct in6_addr ipi6_addr;
    unsigned int ipi6_ifindex;
} CNIOOpenBSD_in6_pktinfo;

int CNIOOpenBSD_sendmmsg(int sockfd, CNIOOpenBSD_mmsghdr *msgvec, unsigned int vlen, int flags);
int CNIOOpenBSD_recvmmsg(int sockfd, CNIOOpenBSD_mmsghdr *msgvec, unsigned int vlen, int flags, struct timespec *timeout);

int CNIOOpenBSD_pthread_set_name_np(pthread_t thread, const char *name);
int CNIOOpenBSD_pthread_get_name_np(pthread_t thread, char *name, size_t len);

// Non-standard socket stuff.
int CNIOOpenBSD_accept4(int sockfd, struct sockaddr *addr, socklen_t *addrlen, int flags);

// cmsghdr handling
struct cmsghdr *CNIOOpenBSD_CMSG_FIRSTHDR(const struct msghdr *);
struct cmsghdr *CNIOOpenBSD_CMSG_NXTHDR(struct msghdr *, struct cmsghdr *);
const void *CNIOOpenBSD_CMSG_DATA(const struct cmsghdr *);
void *CNIOOpenBSD_CMSG_DATA_MUTABLE(struct cmsghdr *);
size_t CNIOOpenBSD_CMSG_LEN(size_t);
size_t CNIOOpenBSD_CMSG_SPACE(size_t);

// awkward time_T pain
extern const int CNIOOpenBSD_SO_TIMESTAMP;
extern const int CNIOOpenBSD_SO_RCVTIMEO;

int CNIOOpenBSD_system_info(struct utsname *uname_data);

extern const unsigned long CNIOOpenBSD_IOCTL_VM_SOCKETS_GET_LOCAL_CID;

const char* CNIOOpenBSD_dirent_dname(struct dirent *ent);

extern const unsigned long CNIOOpenBSD_UTIME_OMIT;
extern const unsigned long CNIOOpenBSD_UTIME_NOW;

extern const long CNIOOpenBSD_UDP_MAX_SEGMENTS;

// A workaround for incorrect nullability annotations in the Android SDK.
// Probably unnecessary on BSD, but copying for consistency for now.
FTS *CNIOOpenBSD_fts_open(char * const *path_argv, int options, int (*compar)(const FTSENT **, const FTSENT **));

#endif
#endif
