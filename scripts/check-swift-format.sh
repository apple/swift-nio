#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2024 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##
set -euo pipefail

log() { printf -- "** %s\n" "$*" >&2; }
error() { printf -- "** ERROR: %s\n" "$*" >&2; }
fatal() { error "$@"; exit 1; }

excluded_files=""

if [ -f .swiftformatignore ]; then
    log "Found swiftformatignore file..."
    excluded_files=$(cat .swiftformatignore | xargs -I% printf ":(exclude)% ")
fi

log "Running swift format format..."
git ls-files -z '*.swift' $excluded_files | xargs -0 swift format format --parallel --in-place

log "Running swift format lint..."

git ls-files -z '*.swift' $excluded_files | xargs -0 swift format lint --strict --parallel

log "Checking for modified files..."

GIT_PAGER= git diff --exit-code '*.swift'

log "✅ Found no formatting issues."
