#!/bin/bash

source defines.sh

token=$(create_token)
start_server "$token"
htdocs=$(get_htdocs "$token")
base="s/o/m/e/r/a/n/d/o/m/f/o/l/d/e/r"
mkdir -p "$htdocs/$base"
dd if=/dev/urandom of="$htdocs/$base/random.bytes" bs=$((1024 * 1024)) count=2
for method in sendfile fileio; do
    do_curl "$token" "http://foobar.com/$method/$base/random.bytes" > "$tmp/random.bytes"
    assert_equal_files "$htdocs/$base/random.bytes" "$tmp/random.bytes"
done
stop_server "$token"
