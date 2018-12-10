#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

set -eu

here="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

case "$(uname -s)" in
    Darwin)
        sed=gsed
        ;;
    *)
        sed=sed
        ;;
esac

if ! hash ${sed} 2>/dev/null; then
    echo "You need sed \"${sed}\" to run this script ..."
    echo
    echo "On macOS: brew install gnu-sed"
    exit 42
fi

# Android ifaddrs
for f in ifaddrs-android.c ifaddrs-android.h; do
    curl -o "${f}" \
         -Ls "https://hg.mozilla.org/releases/mozilla-beta/raw-file/tip/media/mtransport/third_party/nICEr/src/stun/${f}"
done

mv ifaddrs-android.h include/ifaddrs-android.h
"$sed" -i -e 's/#if defined(ANDROID)/#ifdef __ANDROID__/' ifaddrs-android.c
"$sed" -i -e '/#include <sys\/socket.h>/a #include <netdb.h> ' include/ifaddrs-android.h
"$sed" -i -e '1 i\#ifdef __ANDROID__' include/ifaddrs-android.h
"$sed" -i -e '$ i\#endif' include/ifaddrs-android.h
"$sed" -i \
    -e '/struct sockaddr\* ifa_netmask/a union {\nstruct sockaddr *ifu_broadaddr;\nstruct sockaddr *ifu_dstaddr;\n} ifa_ifu;' \
    include/ifaddrs-android.h