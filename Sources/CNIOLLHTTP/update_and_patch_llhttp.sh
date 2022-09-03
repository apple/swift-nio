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
        -e 's/\b\(llhttp__debug\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__on_body\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__on_chunk_complete\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__on_chunk_header\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__on_header_field\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__on_header_field_complete\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__on_header_value\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__on_header_value_complete\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__on_headers_complete\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__on_message_begin\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__on_message_complete\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__on_status\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__on_status_complete\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__on_url\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__on_url_complete\)/c_nio_\1/g' \
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
        -e 's/\b\(llhttp_method_name\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_pause\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_reset\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_resume\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_resume_after_upgrade\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_set_error_reason\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_set_lenient_chunked_length\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_set_lenient_headers\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_set_lenient_keep_alive\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_set_lenient_transfer_encoding\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_settings_init\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_status_name\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__after_headers_complete\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__after_message_complete\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__before_headers_complete\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_message_needs_eof\)/c_nio_\1/g' \
        -e 's/\b\(llhttp_should_keep_alive\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_and_flags\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_is_equal_content_length\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_is_equal_method\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_is_equal_upgrade\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_load_header_state\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_load_http_major\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_load_http_minor\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_load_method\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_load_type\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_mul_add_content_length\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_mul_add_content_length_1\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_mul_add_status_code\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_or_flags\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_or_flags_1\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_or_flags_15\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_or_flags_16\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_or_flags_18\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_or_flags_3\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_or_flags_4\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_or_flags_5\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_or_flags_6\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_store_header_state\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_store_http_major\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_store_http_minor\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_store_method\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_test_flags\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_test_flags_1\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_test_flags_2\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_test_flags_3\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_test_lenient_flags\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_test_lenient_flags_1\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_test_lenient_flags_2\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_test_lenient_flags_5\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_test_lenient_flags_7\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_update_content_length\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_update_finish\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_update_finish_1\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_update_finish_3\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_update_header_state\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_update_header_state_2\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_update_header_state_4\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_update_header_state_5\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_update_header_state_6\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_update_header_state_7\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_update_http_major\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_update_http_minor\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_update_status_code\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_update_type\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_update_type_1\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal__c_update_upgrade\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal_execute\)/c_nio_\1/g' \
        -e 's/\b\(llhttp__internal_init\)/c_nio_\1/g' \
        "$here/c_nio_$f"
done

mv "$here/c_nio_llhttp.h" "$here/include"

compiletmp=$(mktemp -d /tmp/.test_compile_XXXXXX)

for f in *.c; do
    clang -o "$compiletmp/$f.o" -c "$here/$f"
    num_non_nio=$(nm "$compiletmp/$f.o" | grep ' T ' | grep -v c_nio | wc -l)

    test 0 -eq $num_non_nio || {
        echo "ERROR: $num_non_nio exported non-prefixed symbols found"
        nm "$compiletmp/$f.o" | grep ' T ' | grep -v c_nio
        exit 1
    }
done

rm -rf "$compiletmp"
rm -rf "$tmpdir"

