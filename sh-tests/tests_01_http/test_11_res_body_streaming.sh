#!/bin/bash

source defines.sh

token=$(create_token)
start_server "$token"
htdocs=$(get_htdocs "$token")
server_pid=$(get_server_pid "$token")
socket=$(get_socket "$token")

cat > "$tmp/expected" <<EOF
line 1
line 2
line 3
line 4
line 5
line 6
line 7
EOF

{ do_curl "$token" -N http://test/dynamic/continuous || true; } | head -7 > "$tmp/actual"
assert_equal_files "$tmp/expected" "$tmp/actual"

sleep 1 # need to have the next write fail
stop_server "$token"
