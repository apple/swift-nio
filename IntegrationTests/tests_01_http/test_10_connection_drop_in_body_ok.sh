#!/bin/bash

source defines.sh

token=$(create_token)
start_server "$token"
htdocs=$(get_htdocs "$token")
server_pid=$(get_server_pid "$token")
socket=$(get_socket "$token")

kill -0 $server_pid
(
    echo -e 'POST /dynamic/echo HTTP/1.1\r\nContent-Length: 400000\r\n\r\nsome_bytes'
    for f in $(seq 5); do
        echo $f
        sleep 0.1
    done
) | nc -U "$socket"
sleep 0.1
kill -0 $server_pid
stop_server "$token"
