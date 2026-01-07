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
#include <poll.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/timerfd.h>
#include <sys/sysinfo.h>
#include <sys/socket.h>
#include <sys/utsname.h>
#include <sys/xattr.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/vfs.h>
#include <sched.h>
#include <stdbool.h>
#include <errno.h>
#include <pthread.h>
#include <netinet/ip.h>
#if __has_include(<linux/magic.h>)
#include <linux/magic.h>
#endif
#if __has_include(<linux/udp.h>)
#include <linux/udp.h>
#else
#include <netinet/udp.h>
#endif
#include <linux/vm_sockets.h>
#include <fcntl.h>
#include <fts.h>
#include <stdio.h>
#include <dirent.h>
#endif

// We need to include this outside the `#ifdef` so macOS builds don't warn about the missing include,
// but we also need to make sure the system includes come before it on Linux, so we put it down here
// between an `#endif/#ifdef` pair rather than at the top.
#include "liburing_nio.h"

#ifdef __linux__

#if __has_include(<linux/mptcp.h>)
#include <linux/mptcp.h>
#else
// A backported copy of the mptcp_info structure to make programming against
// an uncertain linux kernel easier.
struct mptcp_info {
    uint8_t    mptcpi_subflows;
    uint8_t    mptcpi_add_addr_signal;
    uint8_t    mptcpi_add_addr_accepted;
    uint8_t    mptcpi_subflows_max;
    uint8_t    mptcpi_add_addr_signal_max;
    uint8_t    mptcpi_add_addr_accepted_max;
    uint32_t   mptcpi_flags;
    uint32_t   mptcpi_token;
    uint64_t   mptcpi_write_seq;
    uint64_t   mptcpi_snd_una;
    uint64_t   mptcpi_rcv_nxt;
    uint8_t    mptcpi_local_addr_used;
    uint8_t    mptcpi_local_addr_max;
    uint8_t    mptcpi_csum_enabled;
};
#endif

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

typedef struct {
    struct in6_addr ipi6_addr;
    unsigned int ipi6_ifindex;
} CNIOLinux_in6_pktinfo;

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

// awkward time_T pain
extern const int CNIOLinux_SO_TIMESTAMP;
extern const int CNIOLinux_SO_RCVTIMEO;

bool CNIOLinux_supports_udp_segment();
bool CNIOLinux_supports_udp_gro();

int CNIOLinux_system_info(struct utsname* uname_data);

extern const unsigned long CNIOLinux_IOCTL_VM_SOCKETS_GET_LOCAL_CID;

const char* CNIOLinux_dirent_dname(struct dirent* ent);

int CNIOLinux_renameat2(int oldfd, const char* old, int newfd, const char* newName, unsigned int flags);

extern const int CNIOLinux_O_TMPFILE;
extern const int CNIOLinux_AT_EMPTY_PATH;
extern const unsigned int CNIOLinux_RENAME_NOREPLACE;
extern const unsigned int CNIOLinux_RENAME_EXCHANGE;

extern const unsigned long CNIOLinux_UTIME_OMIT;
extern const unsigned long CNIOLinux_UTIME_NOW;

extern const long CNIOLinux_UDP_MAX_SEGMENTS;

// Filesystem magic constants for cgroup detection
#ifdef __ANDROID__
#if defined(__LP64__)
typedef uint64_t f_type_t;
#else
typedef uint32_t f_type_t;
#endif
#else
#ifdef __FSWORD_T_TYPE
typedef __fsword_t f_type_t;
#else
typedef unsigned long f_type_t;
#endif
#endif

extern const f_type_t CNIOLinux_TMPFS_MAGIC;
extern const f_type_t CNIOLinux_CGROUP2_SUPER_MAGIC;

// Workaround for https://github.com/swiftlang/swift/issues/86149
f_type_t CNIOLinux_statfs_ftype(const char *path);

// A workaround for incorrect nullability annotations in the Android SDK.
FTS *CNIOLinux_fts_open(char * const *path_argv, int options, int (*compar)(const FTSENT **, const FTSENT **));

#endif
#endif
