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

void NIOWSAStartup(void) {
    WSADATA wsa;
    WORD wVersionRequested = MAKEWORD(2, 2);
    int startup = WSAStartup(wVersionRequested, &wsa);
    if (startup != 0) {
        _exit(EXIT_FAILURE);
    }
}

// The function pointer type for C initializers
typedef void (__cdecl *NIOWindowsStartup)(void);

// Declare a function pointer to your function, and put it in the .CRT$XCU section
#pragma section(".CRT$XCU", read)
__declspec(allocate(".CRT$XCU")) NIOWindowsStartup NIOWSAStartup_ptr = NIOWSAStartup;

#endif
