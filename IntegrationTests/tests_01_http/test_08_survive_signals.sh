#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

source defines.sh

token=$(create_token)
start_server "$token"
htdocs=$(get_htdocs "$token")
server_pid=$(get_server_pid "$token")
echo FOO BAR > "$htdocs/some_file.txt"

for f in $(seq 20); do
    # send some signals that are usually discarded
    kill -CHLD "$server_pid" # ignore-unacceptable-language
    kill -URG "$server_pid" # ignore-unacceptable-language
    kill -CONT "$server_pid" # ignore-unacceptable-language
    kill -WINCH "$server_pid" # ignore-unacceptable-language

    do_curl "$token" "http://foobar.com/fileio/some_file.txt" > "$tmp/out.txt" &
    curl_pid=$!
    for g in $(seq 20); do
        kill -URG "$server_pid" # ignore-unacceptable-language
    done
    wait $curl_pid
    cmp "$htdocs/some_file.txt" "$tmp/out.txt"
done

stop_server "$token"
