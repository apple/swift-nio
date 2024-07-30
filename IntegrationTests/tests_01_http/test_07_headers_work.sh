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
do_curl "$token" -H "foo: bar" --http1.0 \
    "http://foobar.com/dynamic/info" > "${tmp:?"tmp variable not set"}/out"
if ! grep -q '("foo", "bar")' "$tmp/out"; then
    fail "couldn't find header in response"
fi
stop_server "$token"
