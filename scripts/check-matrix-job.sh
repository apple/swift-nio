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

test -n "${SWIFT_VERSION:-}" || fatal "SWIFT_VERSION unset"
test -n "${COMMAND:-}" || fatal "COMMAND unset"
swift_version="$SWIFT_VERSION"
command="$COMMAND"
command_5_9="${COMMAND_OVERRIDE_5_9:=""}"
command_5_10="${COMMAND_OVERRIDE_5_10:=""}"
command_6_0="${COMMAND_OVERRIDE_6_0:=""}"
command_6_1="${COMMAND_OVERRIDE_6_1:=""}"
command_6_2="${COMMAND_OVERRIDE_6_2:=""}"
command_nightly_next="${COMMAND_OVERRIDE_NIGHTLY_NEXT:=""}"
command_nightly_main="${COMMAND_OVERRIDE_NIGHTLY_MAIN:=""}"

if [[ "$swift_version" == "5.9" ]] && [[ -n "$command_5_9" ]]; then
  log "Running 5.9 command override"
  eval "$command_5_9"
elif [[ "$swift_version" == "5.10" ]] && [[ -n "$command_5_10" ]]; then
  log "Running 5.10 command override"
  eval "$command_5_10"
elif [[ "$swift_version" == "6.0" ]] && [[ -n "$command_6_0" ]]; then
  log "Running 6.0 command override"
  eval "$command_6_0"
elif [[ "$swift_version" == "6.1" ]] && [[ -n "$command_6_1" ]]; then
  log "Running 6.1 command override"
  eval "$command_6_1"
elif [[ "$swift_version" == "6.2" ]] && [[ -n "$command_6_2" ]]; then
  log "Running 6.2 command override"
  eval "$command_6_2"
elif [[ "$swift_version" == "nightly-next" ]] && [[ -n "$command_nightly_next" ]]; then
  log "Running nightly 6.1 command override"
  eval "$command_nightly_next"
elif [[ "$swift_version" == "nightly-main" ]] && [[ -n "$command_nightly_main" ]]; then
  log "Running nightly main command override"
  eval "$command_nightly_main"
else
  log "Running default command"
  eval "$command"
fi
