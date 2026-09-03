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
        sed="gsed"
        ;;
    *)
        sed="sed"
        ;;
esac

for f in sha1.c sha1.h; do
    ( echo "/* Additional changes for SwiftNIO:"
      echo "    - prefixed all symbols by 'c_nio_'"
      echo "    - removed the _KERNEL include guards"
      echo "    - defined the __min_size macro inline"
      echo "    - included sys/endian.h on Android"
      echo "    - use welcoming language (soundness check)"
      echo "    - ensure BYTE_ORDER is defined"
      echo "*/"
      curl -Ls "https://raw.githubusercontent.com/freebsd/freebsd-src/refs/heads/main/sys/crypto/$f"
    ) > "$here/c_nio_$f"

    for func in sha1_init sha1_pad sha1_loop sha1_result sha1_step; do
        "$sed" -i \
            -e "s/$func/c_nio_$func/g" \
            "$here/c_nio_$f"
    done
done

$sed -e $'/#define _CRYPTO_SHA1_H_/a #include <stdint.h>\\\n#include <stddef.h>' \
     -e 's/u_int\([0-9]\+\)_t/uint\1_t/g'                                        \
     -e 's%#ifdef _KERNEL%#define __min_size(x)	static (x)%g'                    \
     -e 's%#endif /\* _KERNEL \*/%%g'                                            \
     -i "$here/c_nio_sha1.h"

$sed -e 's/u_int\([0-9]\+\)_t/uint\1_t/g'                                        \
     -e '/#include <sys/d'                                                       \
     -e $'/^#include <crypto/c #include "include/CNIOSHA1.h"\\n#include <stdint.h>\\n#include <string.h>\\n#if !defined(bzero)\\n#define bzero(b,l) memset((b), \'\\\\0\', (l))\\n#endif\\n#if !defined(bcopy)\\n#define bcopy(s,d,l) memmove((d), (s), (l))\\n#endif\\n#ifdef __ANDROID__\\n#include <sys/endian.h>\\n#elif defined(__linux__) || defined(__APPLE__) || defined(__wasm32__)\\n#include <sys/types.h>\\n#elif defined(_WIN32) || defined(_WIN64)\\n#ifndef LITTLE_ENDIAN\\n#define LITTLE_ENDIAN 1234\\n#endif\\n#ifndef BIG_ENDIAN\\n#define BIG_ENDIAN 4321\\n #endif\\n#ifndef BYTE_ORDER\\n#define BYTE_ORDER LITTLE_ENDIAN\\n#endif\\n#endif\\n' \
     -e 's/sanit[y]/soundness/g'                                                 \
     -e $'s/#if BYTE_ORDER != BIG_ENDIAN/#if !defined(BYTE_ORDER)\\n#error "BYTE_ORDER not defined"\\n#elif BYTE_ORDER != BIG_ENDIAN/' \
     -i "$here/c_nio_sha1.c"

mv "$here/c_nio_sha1.h" "$here/include/CNIOSHA1.h"

tmp=$(mktemp -d /tmp/.test_compile_XXXXXX)

clang -o "$tmp/test.o" -c "$here/c_nio_sha1.c"
num_non_nio=$(nm "$tmp/test.o" | grep ' T ' | grep -vc c_nio || true)

test 0 -eq "$num_non_nio" || {
    echo "ERROR: $num_non_nio exported non-prefixed symbols found"
    exit 1
}

rm -rf "$tmp"
