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

#if defined(_WIN32)

#include "CNIOWindows.h"

#include <assert.h>
#include <errno.h>
#include <winbase.h>

int CNIOWindows_sendmmsg(SOCKET s, CNIOWindows_mmsghdr *msgvec, unsigned int vlen,
                         int flags) {
  assert(!"sendmmsg not implemented");
  abort();
}

int CNIOWindows_recvmmsg(SOCKET s, CNIOWindows_mmsghdr *msgvec,
                         unsigned int vlen, int flags,
                         struct timespec *timeout) {
  assert(!"recvmmsg not implemented");
  abort();
}

const void *CNIOWindows_CMSG_DATA(const WSACMSGHDR *pcmsg) {
  return WSA_CMSG_DATA(pcmsg);
}

void *CNIOWindows_CMSG_DATA_MUTABLE(LPWSACMSGHDR pcmsg) {
  return WSA_CMSG_DATA(pcmsg);
}

WSACMSGHDR *CNIOWindows_CMSG_FIRSTHDR(const WSAMSG *msg) {
  return WSA_CMSG_FIRSTHDR(msg);
}

WSACMSGHDR *CNIOWindows_CMSG_NXTHDR(const WSAMSG *msg, LPWSACMSGHDR cmsg) {
  return WSA_CMSG_NXTHDR(msg, cmsg);
}

size_t CNIOWindows_CMSG_LEN(size_t length) {
  return WSA_CMSG_LEN(length);
}

size_t CNIOWindows_CMSG_SPACE(size_t length) {
  return WSA_CMSG_SPACE(length);
}

int CNIOWindows_errno(void) {
    return errno;
}

DWORD CNIOWindows_FormatGetLastError(DWORD errorCode, LPSTR errorMsg) {
  return FormatMessage(
    FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
    NULL,
    errorCode,
    0, // Default language
    errorMsg,
    0,
    NULL
  );
}

#endif
