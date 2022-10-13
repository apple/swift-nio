//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// adaptions for llhttp to make it more straightforward to use from Swift

#ifndef C_NIO_LLHTTP_SWIFT
#define C_NIO_LLHTTP_SWIFT

#include "c_nio_llhttp.h"

static inline llhttp_errno_t c_nio_llhttp_execute_swift(llhttp_t *parser,
                                                        const void *data,
                                                        size_t len) {
    return c_nio_llhttp_execute(parser, (const char *)data, len);
}

#endif
