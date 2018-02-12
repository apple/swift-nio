#!/bin/bash

source defines.sh

token=$(create_token)
start_server "$token"
htdocs=$(get_htdocs "$token")
socket=$(get_socket "$token")
echo -e 'GET / HTT\r\n\r\n' | nc -U "$socket" > "$tmp/actual"
backslash_r=$(echo -e '\r')
cat > "$tmp/expected" <<EOF
HTTP/1.0 400 Bad Request$backslash_r
Content-Length: 0$backslash_r
Connection: Close$backslash_r
X-HTTPServer-Error: strict mode assertion$backslash_r
$backslash_r
EOF
assert_equal_files "$tmp/expected" "$tmp/actual"
stop_server "$token"
