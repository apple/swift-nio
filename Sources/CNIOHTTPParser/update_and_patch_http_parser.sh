#!/bin/bash

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

for f in http_parser.c http_parser.h; do
    ( echo "/* Additional changes for SwiftNIO:"
      echo "    - prefixed all symbols by 'c_nio_'"
      echo "*/"
      curl -Ls "https://raw.githubusercontent.com/nodejs/http-parser/master/$f"
    ) > "$here/c_nio_$f"

    "$sed" -i \
        -e 's#"http_parser.h"#"include/c_nio_http_parser.h"#g' \
        -e 's/\b\(http_body_is_final\)/c_nio_\1/g' \
        -e 's/\b\(http_errno_description\)/c_nio_\1/g' \
        -e 's/\b\(http_errno_name\)/c_nio_\1/g' \
        -e 's/\b\(http_message_needs_eof\)/c_nio_\1/g' \
        -e 's/\b\(http_method_str\)/c_nio_\1/g' \
        -e 's/\b\(http_parser_execute\)/c_nio_\1/g' \
        -e 's/\b\(http_parser_init\)/c_nio_\1/g' \
        -e 's/\b\(http_parser_parse_url\)/c_nio_\1/g' \
        -e 's/\b\(http_parser_pause\)/c_nio_\1/g' \
        -e 's/\b\(http_parser_settings_init\)/c_nio_\1/g' \
        -e 's/\b\(http_parser_url_init\)/c_nio_\1/g' \
        -e 's/\b\(http_parser_version\)/c_nio_\1/g' \
        -e 's/\b\(http_should_keep_alive\)/c_nio_\1/g' \
        "$here/c_nio_$f"

tmp=$(mktemp -d /tmp/.test_compile_XXXXXX)

clang -o "$tmp/test.o" -c "$here/c_nio_http_parser.c"
num_non_nio=$(nm "$tmp/test.o" | grep ' T ' | grep -v c_nio | wc -l)

test 0 -eq $num_non_nio || {
    echo "ERROR: $num_non_nio exported non-prefixed symbols found"
    exit 1
}

rm -rf "$tmp"
done
