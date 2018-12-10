//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// adaptions for http_parser to make it more straightforward to use from Swift

#ifndef C_NIO_HTTP_PARSER_SWIFT
#define C_NIO_HTTP_PARSER_SWIFT

#include "c_nio_http_parser.h"

static inline size_t c_nio_http_parser_execute_swift(http_parser *parser,
                                                     const http_parser_settings *settings,
                                                     const void *data,
                                                     size_t len) {
    return c_nio_http_parser_execute(parser, settings, (const char *)data, len);
}

#endif
