#!/bin/bash

source defines.sh

token=$(create_token)
start_server "$token"
htdocs=$(get_htdocs "$token")
server_pid=$(get_server_pid "$token")
socket=$(get_socket "$token")

kill -0 $server_pid

echo -e 'GET /dynamic/count-to-ten HTTP/1.1\r\nConnection: close\r\n\r\n' | \
    nc -U "$socket" > "$tmp/actual"
backslash_r=$(echo -ne '\r')
cat > "$tmp/expected" <<EOF
HTTP/1.1 200 OK$backslash_r
transfer-encoding: chunked$backslash_r
$backslash_r
1$backslash_r
1$backslash_r
1$backslash_r
2$backslash_r
1$backslash_r
3$backslash_r
1$backslash_r
4$backslash_r
1$backslash_r
5$backslash_r
1$backslash_r
6$backslash_r
1$backslash_r
7$backslash_r
1$backslash_r
8$backslash_r
1$backslash_r
9$backslash_r
2$backslash_r
10$backslash_r
0$backslash_r
$backslash_r
EOF
assert_equal_files "$tmp/expected" "$tmp/actual"
stop_server "$token"
