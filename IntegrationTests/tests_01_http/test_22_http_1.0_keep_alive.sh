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
do_curl "$token" -H 'connection: keep-alive' -v --http1.0 \
    "http://foobar.com/dynamic/info" > "$tmp/out_actual" 2>&1
grep -qi '< Connection: keep-alive' "$tmp/out_actual"
grep -qi '< HTTP/1.0 200 OK' "$tmp/out_actual"
stop_server "$token"
