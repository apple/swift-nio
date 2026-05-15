//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
#ifndef C_NIO_FREEBSD_H                                                                                                                                                                                            
#define C_NIO_FREEBSD_H                                                                                                                                                                                            
                                                                                                                                                                                                                     
#if defined(__FreeBSD__)                                                                                                                                                                                           
#include <arpa/inet.h>                                                                                                                                                                                             
#include <netinet/in.h>                                                                                                                                                                                            
#include <netinet/ip.h>                                                                                                                                                                                            
#include <sys/socket.h>                                                                                                                                                                                            

const char *CNIOFreeBSD_inet_ntop(int af, const void *src, char *dst, socklen_t size);                                                                                                                             
int CNIOFreeBSD_inet_pton(int af, const char *src, void *dst);

#endif                                                                                                                                                                                                             
                                                                                                                                                                                                                     
#endif
