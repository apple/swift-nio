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

for f in sha1.c sha1.h; do
    ( echo "/* Additional changes for SwiftNIO:"
      echo "    - prefixed all symbols by 'c_nio_'"
      echo "    - replaced the sys/systm.h include by strings.h"
      echo "    - removed the _KERNEL include guards"
      echo "    - defined the __min_size macro inline"
      echo "    - included sys/types.h in c_nio_sha1.h"
      echo "*/"
      curl -Ls "https://raw.githubusercontent.com/freebsd/freebsd/master/sys/crypto/$f"
    ) > "$here/c_nio_$f"

    for func in sha1_init sha1_pad sha1_loop sha1_result; do
        "$sed" -i \
            -e "s/$func/c_nio_$func/g" \
            -e 's#<sys/systm.h>#<strings.h>#g' \
            -e 's#<crypto/sha1.h>#"include/c_nio_sha1.h"#g' \
            -e 's%#ifdef _KERNEL%#define __min_size(x)	static (x)%g' \
            -e 's%#endif /\* _KERNEL \*/%%g' \
            -e 's%__FBSDID("$FreeBSD$");%%g' \
            "$here/c_nio_$f"
    done
done

gsed -i '/#define _CRYPTO_SHA1_H_/a #include <sys/types.h>' "$here/c_nio_sha1.h"
mv "$here/c_nio_sha1.h" "$here/include/c_nio_sha1.h"

tmp=$(mktemp -d /tmp/.test_compile_XXXXXX)

clang -o "$tmp/test.o" -c "$here/c_nio_sha1.c"
num_non_nio=$(nm "$tmp/test.o" | grep ' T ' | grep -v c_nio | wc -l)

test 0 -eq $num_non_nio || {
    echo "ERROR: $num_non_nio exported non-prefixed symbols found"
    exit 1
}

rm -rf "$tmp"
