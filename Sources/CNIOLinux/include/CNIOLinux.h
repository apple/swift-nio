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
#ifndef C_NIO_LINUX_H
#define C_NIO_LINUX_H

#ifdef __linux__
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/timerfd.h>
#include <sys/sysinfo.h>
#include <sys/socket.h>
#include <sched.h>
#include <errno.h>
#include <pthread.h>
#include <netinet/ip.h>

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
} CNIOLinux_mmsghdr;

int CNIOLinux_sendmmsg(int sockfd, CNIOLinux_mmsghdr *msgvec, unsigned int vlen, int flags);
int CNIOLinux_recvmmsg(int sockfd, CNIOLinux_mmsghdr *msgvec, unsigned int vlen, int flags, struct timespec *timeout);

int CNIOLinux_pthread_setname_np(pthread_t thread, const char *name);
int CNIOLinux_pthread_getname_np(pthread_t thread, char *name, size_t len);

// Non-standard socket stuff.
int CNIOLinux_accept4(int sockfd, struct sockaddr *addr, socklen_t *addrlen, int flags);

// Thread affinity stuff.
int CNIOLinux_pthread_setaffinity_np(pthread_t thread, size_t cpusetsize, const cpu_set_t *cpuset);
int CNIOLinux_pthread_getaffinity_np(pthread_t thread, size_t cpusetsize, cpu_set_t *cpuset);
void CNIOLinux_CPU_SET(int cpu, cpu_set_t *set);
void CNIOLinux_CPU_ZERO(cpu_set_t *set);
int CNIOLinux_CPU_ISSET(int cpu, cpu_set_t *set);
int CNIOLinux_CPU_SETSIZE();

// cmsghdr handling
struct cmsghdr *CNIOLinux_CMSG_FIRSTHDR(const struct msghdr *);
struct cmsghdr *CNIOLinux_CMSG_NXTHDR(struct msghdr *, struct cmsghdr *);
const void *CNIOLinux_CMSG_DATA(const struct cmsghdr *);
void *CNIOLinux_CMSG_DATA_MUTABLE(struct cmsghdr *);
size_t CNIOLinux_CMSG_LEN(size_t);
size_t CNIOLinux_CMSG_SPACE(size_t);
#endif
#endif
