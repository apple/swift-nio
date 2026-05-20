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

void CNIOFreeBSD_i_do_nothing_just_working_around_a_darwin_toolchain_bug(void) {}

#if defined(__FreeBSD__)                                                                                                                                                                                           
#include <arpa/inet.h>                                                                                                                                                                                             
                                                                                                                                                                                                                     
const char *CNIOFreeBSD_inet_ntop(int af, const void *src, char *dst, socklen_t size) {                                                                                                                            
    return inet_ntop(af, src, dst, size);                                                                                                                                                                          
}                                                                                                                                                                                                                  
                  
int CNIOFreeBSD_inet_pton(int af, const char *src, void *dst) {                                                                                                                                                    
    return inet_pton(af, src, dst);
}                                                                                                                                                                                                                  
#endif