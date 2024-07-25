#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2017-2022 Apple Inc. and the SwiftNIO project authors
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

if ! hash ${sed} 2>/dev/null; then
    echo "You need sed \"${sed}\" to run this script ..."
    echo
    echo "On macOS: brew install gnu-sed"
    exit 42
fi

tmpdir=$(mktemp -d /tmp/.llhttp_vendor_XXXXXX)
cd "$tmpdir"
git clone https://github.com/nodejs/llhttp.git
cd llhttp
npm install
make

cp "$tmpdir/llhttp/LICENSE-MIT" "$here"
cp "$tmpdir/llhttp/build/llhttp.h" "$here"
cp "$tmpdir/llhttp/build/c/llhttp.c" "$here"
cp "$tmpdir/llhttp/src/native/"*.c "$here"

cd "$here"

# The sed script in here has gotten a little unwieldy, we should consider doing
# something smarter. For now it's good enough.
for f in *.{c,h}; do
    ( echo "/* Additional changes for SwiftNIO:"
      echo "    - prefixed all symbols by 'c_nio_'"
      echo "*/"
    ) > "c_nio_$f"
    cat "$f" >> "$here/c_nio_$f"
    rm "$f"
    "$sed" -i \
        -e 's#"llhttp.h"#"include/c_nio_llhttp.h"#g' \
        -e 's/\b\(llhttp__after_headers_complete\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__after_message_complete\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__before_headers_complete\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__debug\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__on_\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_errno_name\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_execute\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_finish\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_get_errno\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_get_error_pos\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_get_error_reason\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_get_http_major\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_get_http_minor\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_get_method\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_get_status_code\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_get_type\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_get_upgrade\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_init\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_message_needs_eof\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_method_name\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_pause\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_reset\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_resume\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_resume_after_upgrade\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_set_error_reason\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_set_lenient_chunked_length\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_set_lenient_data_after_close\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_set_lenient_headers\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_set_lenient_keep_alive\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_set_lenient_optional_crlf_after_chunk\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_set_lenient_optional_lf_after_cr\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_set_lenient_transfer_encoding\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_set_lenient_version\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_settings_init\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_should_keep_alive\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_status_name\)/c_nio_\1/g' \
        "$here/c_nio_$f"
done

mv "$here/c_nio_llhttp.h" "$here/include"

compiletmp=$(mktemp -d /tmp/.test_compile_XXXXXX)

for f in *.c; do
    clang -o "$compiletmp/$f.o" -c "$here/$f"
    num_non_nio=$(nm "$compiletmp/$f.o" | grep ' T ' | grep -cv c_nio)

    test 0 -eq "$num_non_nio" || {
        echo "ERROR: $num_non_nio exported non-prefixed symbols found"
        nm "$compiletmp/$f.o" | grep ' T ' | grep -v c_nio
        exit 1
    }
done

rm -rf "$compiletmp"
rm -rf "$tmpdir"

