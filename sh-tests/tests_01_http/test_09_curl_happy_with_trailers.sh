#!/bin/bash

source defines.sh

token=$(create_token)
start_server "$token"
htdocs=$(get_htdocs "$token")
server_pid=$(get_server_pid "$token")
backslash_r=$(echo -ne '\r')
cat > "$htdocs/some_file.txt" <<EOF
$server_pid$backslash_r
$server_pid$backslash_r
$server_pid$backslash_r
$server_pid$backslash_r
EOF
do_curl "$token" \
    "http://foobar.com/dynamic/trailers" \
    "http://foobar.com/dynamic/trailers" \
    "http://foobar.com/dynamic/trailers" \
    "http://foobar.com/dynamic/trailers" \
    > "$tmp/out.txt"
assert_equal_files "$htdocs/some_file.txt" "$tmp/out.txt"
stop_server "$token"
