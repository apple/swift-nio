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

set -eu
swift_bin=swift

cp -R "test_01_resources/template"/* "$tmp/"
nio_root="$PWD/../.."

(
set -eu
cd "$tmp"

function make_git_commit_all() {
    git init
    git config --local user.email does@really-not.matter
    git config --local user.name 'Does Not Matter'
    git add .
    git commit -m 'everything'
}

cd HookedFunctions
make_git_commit_all
cd ..

cd AtomicCounter
make_git_commit_all
cd ..

mkdir swift-nio
cd swift-nio
cat > Package.swift <<"EOF"
// swift-tools-version:4.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(name: "swift-nio")
EOF
make_git_commit_all
cd ..

"$swift_bin" package edit --path "$nio_root" swift-nio
"$swift_bin" run -c release | tee "$tmp/output"
)

for test in 1000_reqs_1_conn 1_reqs_1000_conn ping_pong_1000_reqs_1_conn bytebuffer_lots_of_rw future_lots_of_callbacks; do
    cat "$tmp/output"  # helps debugging
    total_allocations=$(grep "^$test.total_allocations:" "$tmp/output" | cut -d: -f2 | sed 's/ //g')
    not_freed_allocations=$(grep "^$test.remaining_allocations:" "$tmp/output" | cut -d: -f2 | sed 's/ //g')
    max_allowed_env_name="MAX_ALLOCS_ALLOWED_$test"

    info "$test: allocations not freed: $not_freed_allocations"
    info "$test: total number of mallocs: $total_allocations"

    assert_less_than "$not_freed_allocations" 5     # allow some slack
    assert_greater_than "$not_freed_allocations" -5 # allow some slack
    assert_greater_than "$total_allocations" 1000
    if [[ -z "${!max_allowed_env_name+x}" ]]; then
        if [[ -z "${!max_allowed_env_name+x}" ]]; then
            warn "no reference number of allocations set (set to \$$max_allowed_env_name)"
            warn "to set current number:"
            warn "    export $max_allowed_env_name=$total_allocations"
        fi
    else
        assert_less_than_or_equal "$total_allocations" "${!max_allowed_env_name}"
    fi
done
