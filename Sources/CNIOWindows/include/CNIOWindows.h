//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#ifndef C_NIO_WINDOWS_H
#define C_NIO_WINDOWS_H

#if defined(_WIN32)

#include <WinSock2.h>
#include <time.h>
#include <stdint.h>

#define NIO(name) CNIOWindows_ ## name

// This is a DDK type which is not available in the WinSDK as it is not part of
// the shared, usermode (um), or ucrt portions of the code.  We must replicate
// this datastructure manually from the MSDN references or the DDK.
// https://docs.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_reparse_data_buffer
typedef struct NIO(_REPARSE_DATA_BUFFER) {
  ULONG   ReparseTag;
  USHORT  ReparseDataLength;
  USHORT  Reserved;
  union {
    struct {
      USHORT  SubstituteNameOffset;
      USHORT  SubstituteNameLength;
      USHORT  PrintNameOffset;
      USHORT  PrintNameLength;
      ULONG   Flags;
      WCHAR   PathBuffer[1];
    } SymbolicLinkReparseBuffer;
    struct {
      USHORT  SubstituteNameOffset;
      USHORT  SubstituteNameLength;
      USHORT  PrintNameOffset;
      USHORT  PrintNameLength;
      WCHAR   PathBuffer[1];
    } MountPointReparseBuffer;
    struct {
      UCHAR   DataBuffer[1];
    } GenericReparsaeBuffer;
  } DUMMYUNIONNAME;
} NIO(REPARSE_DATA_BUFFER), *NIO(PREPARSE_DATA_BUFFER);

typedef struct {
  WSAMSG msg_hdr;
  unsigned int msg_len;
} NIO(mmsghdr);

static inline __attribute__((__always_inline__)) int
NIO(getsockopt)(SOCKET s, int level, int optname, void *optval, int *optlen) {
  return getsockopt(s, level, optname, optval, optlen);
}

static inline __attribute__((__always_inline__)) int
NIO(recv)(SOCKET s, void *buf, int len, int flags) {
  return recv(s, buf, len, flags);
}

static inline __attribute__((__always_inline__)) int
NIO(recvfrom)(SOCKET s, void *buf, int len, int flags, SOCKADDR *from,
              int *fromlen) {
  return recvfrom(s, buf, len, flags, from, fromlen);
}

static inline __attribute__((__always_inline__)) int
NIO(send)(SOCKET s, const void *buf, int len, int flags) {
  return send(s, buf, len, flags);
}

static inline __attribute__((__always_inline__)) int
NIO(setsockopt)(SOCKET s, int level, int optname, const void *optval,
                int optlen) {
  return setsockopt(s, level, optname, optval, optlen);
}

static inline __attribute__((__always_inline__)) int
NIO(sendto)(SOCKET s, const void *buf, int len, int flags, const SOCKADDR *to,
            int tolen) {
  return sendto(s, buf, len, flags, to, tolen);
}

int NIO(sendmmsg)(SOCKET s, NIO(mmsghdr) *msgvec, unsigned int vlen, int flags);

int NIO(recvmmsg)(SOCKET s, NIO(mmsghdr) *msgvec, unsigned int vlen, int flags,
                  struct timespec *timeout);


const void *NIO(CMSG_DATA)(const WSACMSGHDR *);
void *NIO(CMSG_DATA_MUTABLE)(LPWSACMSGHDR);

WSACMSGHDR *NIO(CMSG_FIRSTHDR)(const WSAMSG *);
WSACMSGHDR *NIO(CMSG_NXTHDR)(const WSAMSG *, LPWSACMSGHDR);

size_t NIO(CMSG_LEN)(size_t);
size_t NIO(CMSG_SPACE)(size_t);

#undef NIO

#endif

#endif
