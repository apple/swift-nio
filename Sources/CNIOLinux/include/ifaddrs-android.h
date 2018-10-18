#ifdef __ANDROID__
/*
Copyright (c) 2011, The WebRTC project authors. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

  * Neither the name of Google nor the names of its contributors may
    be used to endorse or promote products derived from this software
    without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

#ifndef WEBRTC_BASE_IFADDRS_ANDROID_H_
#define WEBRTC_BASE_IFADDRS_ANDROID_H_

#include <stdio.h>
#include <sys/socket.h>
#include <netdb.h> 

/* Implementation of getifaddrs for Android.
 * Fills out a list of ifaddr structs (see below) which contain information
 * about every network interface available on the host.
 * See 'man getifaddrs' on Linux or OS X (nb: it is not a POSIX function). */
struct ifaddrs {
  struct ifaddrs* ifa_next;
  char* ifa_name;
  unsigned int ifa_flags;
  struct sockaddr* ifa_addr;
  struct sockaddr* ifa_netmask;
union {
struct sockaddr *ifu_broadaddr;
struct sockaddr *ifu_dstaddr;
} ifa_ifu;
  /* Real ifaddrs has broadcast, point to point and data members.
   * We don't need them (yet?). */
};

int android_getifaddrs(struct ifaddrs** result);
void android_freeifaddrs(struct ifaddrs* addrs);

#endif  /* WEBRTC_BASE_IFADDRS_ANDROID_H_ */
#endif

