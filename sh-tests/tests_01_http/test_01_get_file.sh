#!/bin/bash

source defines.sh

token=$(create_token)
start_server "$token"
htdocs=$(get_htdocs "$token")
echo FOO BAR > "$htdocs/some_file.txt"
for method in sendfile fileio; do
    do_curl "$token" "http://foobar.com/$method/some_file.txt" > "$tmp/out.txt"
    assert_equal_files "$htdocs/some_file.txt" "$tmp/out.txt"
done
stop_server "$token"
