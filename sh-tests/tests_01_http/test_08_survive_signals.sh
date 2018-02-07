#!/bin/bash

source defines.sh

token=$(create_token)
start_server "$token"
htdocs=$(get_htdocs "$token")
server_pid=$(get_server_pid "$token")
echo FOO BAR > "$htdocs/some_file.txt"

for f in $(seq 20); do
    # send some signals that are usually discarded
    kill -CHLD "$server_pid"
    kill -URG "$server_pid"
    kill -CONT "$server_pid"
    kill -WINCH "$server_pid"

    do_curl "$token" "http://foobar.com/fileio/some_file.txt" > "$tmp/out.txt" &
    curl_pid=$!
    for g in $(seq 20); do
        kill -URG "$server_pid"
    done
    wait $curl_pid
    cmp "$htdocs/some_file.txt" "$tmp/out.txt"
done

stop_server "$token"
