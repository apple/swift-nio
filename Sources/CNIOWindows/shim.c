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

int CNIOWindows_sendmmsg(SOCKET s, CNIOWindows_mmsghdr *msgvec,
                         unsigned int vlen, int flags) {
  abort();
}

int CNIOWindows_recvmmsg(SOCKET s, CNIOWindows_mmsghdr *msgvec,
                         unsigned int vlen, int flags,
                         struct timespec *timeout) {
  abort();
}

#endif
