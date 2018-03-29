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
cd "$tmp"

function make_git_commit_all() {
    git init
    git config --local user.email does@really-not.matter
    git config --local user.name 'Does Not Matter'
    git add .
    git commit -m 'everything'
}

cd HookedFree
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
"$swift_bin" run -c release > "$tmp/output"
)

for test in 1000_reqs_1_conn; do
    allocs=$(grep "$test:" "$tmp/output" | cut -d: -f2 | sed 's/ //g')
    max_allowed_env_name="MAX_ALLOCS_ALLOWED_$test"

    assert_greater_than "$allocs" 1000
    if [[ -z "${!max_allowed_env_name+x}" ]]; then
        if [[ -z "${!max_allowed_env_name+x}" ]]; then
            warn "no reference number of allocations set (set to \$$max_allowed_env_name)"
            warn "to set current number:"
            warn "    export $max_allowed_env_name=$allocs"
        fi
    else
        assert_less_than_or_equal "$allocs" "${!max_allowed_env_name}"
    fi
done
