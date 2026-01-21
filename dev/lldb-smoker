#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

set -eu

here="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

number_of_breaks=2000
package_dir=$(cd "${1-"$here/.."}" && pwd -P)
files=( "$package_dir"/Sources/*/*.swift "$package_dir"/Tests/*/*.swift )

function random_array_element() {
    arr=("${!1}")
    echo ${arr["$[RANDOM % ${#arr[@]}]"]}
}

function number_of_lines() {
    wc -l < "$1"
}

function random_line_number() {
    echo $(( 1 + ( RANDOM % $(number_of_lines "$1") ) ))
}

echo "Package dir: $package_dir"
( set -eux && cd "$package_dir" && swift build --build-tests )
xctest_bundle=( "$package_dir/.build/debug"/*PackageTests.xctest )
echo "xctest bundle: $xctest_bundle"

if [[ ! -e "$xctest_bundle" ]]; then
    echo >&2 "ERROR: Couldn't find xctest bundle at $xctest_bundle"
    exit 1
fi
run_command=()
if [[ "$(uname -s)" == Darwin ]]; then
    xctest=$(xcrun -f xctest)
    run_command+=( "$xctest" "$xctest_bundle" )
else
    run_command+=( "$xctest_bundle" )
fi

lldb_file=()
for f in $(seq "$number_of_breaks"); do
    file=$(random_array_element "files[@]")
    line=$(random_line_number "$file")

    lldb_file+=( "break set -o true -f '$file' -l '$line'" )
done
lldb_file+=( run )
for f in $(seq "$number_of_breaks"); do
    lldb_file+=( 'frame variable --show-all-children' )

    lldb_file+=( cont )
done

lldb_response_file=$(mktemp /tmp/lldb-smoker_XXXXXX)
for command in "${lldb_file[@]}"; do
    echo "$command" >> "$lldb_response_file"
done

echo "LLDB response file: $lldb_response_file"
sleep 0.5
lldb_command=( lldb --batch --source "$lldb_response_file" -- \
    "${run_command[@]}" )

set +e
set -x
"${lldb_command[@]}"
set +x
set -e

echo "LLDB response file: $lldb_response_file"
echo "LLDB command: ${lldb_command[*]}"
