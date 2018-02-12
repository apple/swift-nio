#!/bin/bash

source defines.sh

token=$(create_token)
start_server "$token" tcp
htdocs=$(get_htdocs "$token")
echo -n '[IPv4]127.0.0.1' > "$tmp/expected_ipv4"
echo -n '[IPv6]::1' > "$tmp/expected_ipv6"
do_curl "$token" "http://localhost:$(get_server_port "$token")/dynamic/client-ip" > "$tmp/actual"
if grep -q '\[IPv4\]127.0.0.1' "$tmp/actual"; then
    true
elif grep -q '\[IPv6\]::1' "$tmp/actual"; then
    true
else
    fail "could not find client IP in $(cat "$tmp/actual")"
fi
stop_server "$token"
