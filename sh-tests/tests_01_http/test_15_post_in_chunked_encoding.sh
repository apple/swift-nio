#!/bin/bash

source defines.sh

token=$(create_token)
start_server "$token"
dd if=/dev/urandom of="$tmp/random.bytes" bs=$((64*1024)) count=1
do_curl "$token" -X POST --header "Transfer-Encoding: chunked" \
    --data-binary "@$tmp/random.bytes" \
    "http://foobar.com/dynamic/echo" > "$tmp/random.bytes.out"
cmp "$tmp/random.bytes" "$tmp/random.bytes.out"
stop_server "$token"
