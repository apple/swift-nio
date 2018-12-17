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

set -eu

here="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

function usage() {
    echo "$0 -l"
    echo
    echo "OPTIONS:"
    echo "  -l: Only dependencies of library targets"
    echo "  -r: Reverse the output"
    echo "  -d <PACKAGE>: Prints the dependencies of the given package"
}

function tac_compat() {
    sed '1!G;h;$!d'
}

tmpfile=$(mktemp /tmp/.list_topsorted_dependencies_XXXXXX)

only_libs=false
do_reversed=false
package_dependency=""
while getopts "lrd:" opt; do
    case $opt in
        l)
            only_libs=true
            ;;
        r)
            do_reversed=true
            ;;
        d)
            package_dependency="$OPTARG"
            ;;
        \?)
            usage
            exit 1
            ;;
    esac
done

transform=cat
if $do_reversed; then
    transform=tac_compat
fi

if [[ ! -z "$package_dependency" ]]; then
  swift package dump-package | jq -r ".targets |
                                      map(select(.name == \"$package_dependency\" and .type == \"regular\") | .dependencies | map(.name)) | .[] | .[]"
  exit 0
fi

(
cd "$here/.."
if $only_libs; then
    swift package dump-package | jq '.products |
                                     map(select(.product_type != "library")) |
                                     map(.name) | .[]' | tr -d '"' \
                                     >> "$tmpfile"
fi
swift package dump-package | jq '.targets |
                                 map(.name as $name |
                                 select(.name == $name and .type == "regular") |
                                 { "\($name)": .dependencies | map(.name) } ) |
                                 map(to_entries[]) |
                                 map("\(.key) \(.value | .[])") |
                                 .[]' | \
                                     tr -d '"' | \
                                     tsort | "$transform" | while read -r line; do
    if ! grep -q "^$line\$" "$tmpfile"; then
        echo "$line"
    fi
done
)

rm "$tmpfile"
