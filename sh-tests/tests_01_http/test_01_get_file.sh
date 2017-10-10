#!/bin/bash

source defines.sh

token=$(create_token)
start_server "$token"
htdocs=$(get_htdocs "$token")
echo FOO BAR > "$htdocs/some_file.txt"
do_curl "$token" "http://foobar.com/some_file.txt" > "$tmp/out.txt"
assert_equal_files "$htdocs/some_file.txt" "$tmp/out.txt"
stop_server "$token"
