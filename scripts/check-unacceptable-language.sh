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

test -n "${UNACCEPTABLE_WORD_LIST:-}" || fatal "UNACCEPTABLE_WORD_LIST unset"

log "Checking for unacceptable language..."
unacceptable_language_lines=$(git grep \
  -i -I -w \
  -H -n --column \
  -E "${UNACCEPTABLE_WORD_LIST// /|}" | grep -v "ignore-unacceptable-language"
) || true | /usr/bin/paste -s -d " " -

if [ -n "${unacceptable_language_lines}" ]; then
    fatal " ❌ Found unacceptable language:
${unacceptable_language_lines}
"
fi

log "✅ Found no unacceptable language."