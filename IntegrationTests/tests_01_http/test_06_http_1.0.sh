#!/bin/bash

source defines.sh

token=$(create_token)
start_server "$token"
echo foo > "$tmp/out_expected"
do_curl "$token" --data-binary "@$tmp/out_expected" --http1.0 \
    "http://foobar.com/dynamic/echo_balloon" > "$tmp/out_actual"
assert_equal_files "$tmp/out_expected" "$tmp/out_actual"
stop_server "$token"
