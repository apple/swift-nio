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

#include <Winsock2.h>

#include <stdlib.h>

#pragma section(".CRT$XCU", read)

static void __cdecl
NIOWSAStartup(void) {
    WSADATA wsa;
    WORD wVersionRequested = MAKEWORD(2, 2);
    if (!WSAStartup(wVersionRequested, &wsa)) {
        _exit(EXIT_FAILURE);
    }
}

__declspec(allocate(".CRT$XCU"))
static void (*pNIOWSAStartup)(void) = &NIOWSAStartup;

#endif
