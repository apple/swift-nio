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

# shellcheck source=IntegrationTests/tests_01_http/defines.sh
source defines.sh

token=$(create_token)
start_server "$token"
htdocs=$(get_htdocs "$token")
echo FOO BAR > "$htdocs/some_file.txt"
touch "$htdocs/empty"
for file in some_file.txt empty; do
    for method in sendfile fileio; do
        do_curl "$token" "http://foobar.com/$method/$file" > "${tmp:?"tmp variable not set"}/out.txt"
        assert_equal_files "$htdocs/$file" "$tmp/out.txt"
    done
done
stop_server "$token"
