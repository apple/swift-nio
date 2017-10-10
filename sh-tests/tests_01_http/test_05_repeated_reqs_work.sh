#!/bin/bash

source defines.sh

token=$(create_token)
start_server "$token"
do_curl "$token" "http://foobar.com/dynamic/pid" > "$tmp/out"
for f in $(seq 100); do
    do_curl "$token" "http://foobar.com/dynamic/pid" > "$tmp/out2"
    assert_equal_files "$tmp/out" "$tmp/out2"
done
stop_server "$token"
