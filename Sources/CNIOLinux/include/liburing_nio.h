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

#ifndef LIBURING_NIO_H
#define LIBURING_NIO_H

#ifdef __linux__

#ifdef SWIFTNIO_USE_IO_URING

#if __has_include(<liburing.h>)
#include <liburing.h>
#else
#error "SWIFTNIO_USE_IO_URING specified but liburing.h not available. You need to install https://github.com/axboe/liburing."
#endif

// OR in the IOSQE_IO_LINK flag, couldn't access the define from Swift
void CNIOLinux_io_uring_set_link_flag(struct io_uring_sqe *sqe);

// No way I managed to get this even when defining _GNU_SOURCE properly. Argh.
unsigned int CNIOLinux_POLLRDHUP();

#endif

#endif /* __linux__ */

#endif /* LIBURING_NIO_H */
