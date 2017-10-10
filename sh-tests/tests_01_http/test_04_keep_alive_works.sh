#!/bin/bash

source defines.sh

token=$(create_token)
start_server "$token"
server_pid=$(get_server_pid "$token")
echo -n \
    "$server_pid$server_pid$server_pid$server_pid$server_pid$server_pid$server_pid$server_pid$server_pid$server_pid" \
    > "$tmp/out_expected"
do_curl "$token" \
    "http://foobar.com/dynamic/pid" \
    "http://foobar.com/dynamic/pid" \
    "http://foobar.com/dynamic/pid" \
    "http://foobar.com/dynamic/pid" \
    "http://foobar.com/dynamic/pid" \
    "http://foobar.com/dynamic/pid" \
    "http://foobar.com/dynamic/pid" \
    "http://foobar.com/dynamic/pid" \
    "http://foobar.com/dynamic/pid" \
    "http://foobar.com/dynamic/pid" \
    > "$tmp/out_actual"
assert_equal_files "$tmp/out_expected" "$tmp/out_actual"
stop_server "$token"
