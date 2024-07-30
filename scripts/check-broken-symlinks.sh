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

log "Checking for broken symlinks..."
num_broken_symlinks=0
while read -r -d '' file; do
  if ! test -e "./${file}"; then
    error "Broken symlink: ${file}"
    ((num_broken_symlinks++))
  fi
done < <(git ls-files -z)

if [ "${num_broken_symlinks}" -gt 0 ]; then
  fatal "❌ Found ${num_broken_symlinks} symlinks."
fi

log "✅ Found 0 symlinks."
