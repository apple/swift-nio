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

int NIO(sendmmsg)(SOCKET s, NIO(mmsghdr) *msgvec, unsigned int vlen, int flags) {
  assert(!"sendmmsg not implemented");
  abort();
}

int NIO(recvmmsg)(SOCKET s, NIO(mmsghdr) *msgvec, unsigned int vlen, int flags,
                  struct timespec *timeout) {
  assert(!"recvmmsg not implemented");
  abort();
}

#endif
