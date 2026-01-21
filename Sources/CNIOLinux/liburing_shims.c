//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// Support functions for liburing

// Check if this is needed, copied from shim.c to avoid possible problems due to:
// Xcode's Archive builds with Xcode's Package support struggle with empty .c files
// (https://bugs.swift.org/browse/SR-12939).
void CNIOLinux_i_do_nothing_just_working_around_a_darwin_toolchain_bug2(void) {}

#ifdef __linux__

#ifdef SWIFTNIO_USE_IO_URING

#define _GNU_SOURCE
#include <CNIOLinux.h>
#include <signal.h>
#include <sys/poll.h>

void CNIOLinux_io_uring_set_link_flag(struct io_uring_sqe *sqe)
{
    sqe->flags |= IOSQE_IO_LINK;
    return;
}

unsigned int CNIOLinux_POLLRDHUP()
{
    return POLLRDHUP;
}

#endif

#endif
