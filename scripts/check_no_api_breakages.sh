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

# repodir
function all_modules() {
    local repodir="$1"
    (
    set -eu
    cd "$repodir"
    swift package dump-package | jq '.products |
                                     map(select(.type | has("library") )) |
                                     map(.name) | .[]' | tr -d '"'
    )
}

# repodir tag output
function build_and_do() {
    local repodir=$1
    local tag=$2
    local output=$3

    (
    cd "$repodir"
    git checkout -q "$tag"
    swift build
    while read -r module; do
        swift api-digester -sdk "$sdk" -dump-sdk -module "$module" \
            -o "$output/$module.json" -I "$repodir/.build/debug"
    done < <(all_modules "$repodir")
    )
}

function usage() {
    echo >&2 "Usage: $0 REPO-GITHUB-URL NEW-VERSION OLD-VERSIONS..."
    echo >&2
    echo >&2 "This script requires a Swift 5.1+ toolchain."
    echo >&2
    echo >&2 "Examples:"
    echo >&2
    echo >&2 "Check between master and tag 2.1.1 of swift-nio:"
    echo >&2 "  $0 https://github.com/apple/swift-nio master 2.1.1"
    echo >&2
    echo >&2 "Check between HEAD and commit 64cf63d7 using the provided toolchain:"
    echo >&2 "  xcrun --toolchain org.swift.5120190702a $0 ../some-local-repo HEAD 64cf63d7"
}

if [[ $# -lt 3 ]]; then
    usage
    exit 1
fi

sdk=/
if [[ "$(uname -s)" == Darwin ]]; then
    sdk=$(xcrun --show-sdk-path)
fi

hash jq 2> /dev/null || { echo >&2 "ERROR: jq must be installed"; exit 1; }
tmpdir=$(mktemp -d /tmp/.check-api_XXXXXX)
repo_url=$1
new_tag=$2
shift 2

repodir="$tmpdir/repo"
git clone "$repo_url" "$repodir"
git -C "$repodir" fetch -q origin '+refs/pull/*:refs/remotes/origin/pr/*'
errors=0

for old_tag in "$@"; do
    mkdir "$tmpdir/api-old"
    mkdir "$tmpdir/api-new"

    echo "Checking public API breakages from $old_tag to $new_tag"

    build_and_do "$repodir" "$new_tag" "$tmpdir/api-new/"
    build_and_do "$repodir" "$old_tag" "$tmpdir/api-old/"

    for f in "$tmpdir/api-new"/*; do
        f=$(basename "$f")
        report="$tmpdir/$f.report"
        if [[ ! -f "$tmpdir/api-old/$f" ]]; then
            echo "NOTICE: NEW MODULE $f"
            continue
        fi

        echo -n "Checking $f... "
        swift api-digester -sdk "$sdk" -diagnose-sdk \
            --input-paths "$tmpdir/api-old/$f" -input-paths "$tmpdir/api-new/$f" 2>&1 \
            > "$report" 2>&1

        if ! shasum "$report" | grep -q cefc4ee5bb7bcdb7cb5a7747efa178dab3c794d5; then
            echo ERROR
            echo >&2 "=============================="
            echo >&2 "ERROR: public API change in $f"
            echo >&2 "=============================="
            cat >&2 "$report"
            errors=$(( errors + 1 ))
        else
            echo OK
        fi
    done
    rm -rf "$tmpdir/api-new" "$tmpdir/api-old"
done

if [[ "$errors" == 0 ]]; then
    echo "OK, all seems good"
fi
echo done
exit "$errors"
