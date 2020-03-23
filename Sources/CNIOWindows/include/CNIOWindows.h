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

#define NIO(name) CNIOWindows_ ## name

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

#undef NIO

#endif

#endif
