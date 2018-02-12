#!/bin/bash

source defines.sh

token=$(create_token)
start_server "$token"
do_curl "$token" -H "foo: bar" --http1.0 \
    "http://foobar.com/dynamic/info" > "$tmp/out"
if ! grep -q '("foo", "bar")' "$tmp/out"; then
    fail "couldn't find header in response"
fi
stop_server "$token"
