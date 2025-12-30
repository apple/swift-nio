#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

set -uo pipefail

log() { printf -- "** %s\n" "$*" >&2; }
error() { printf -- "** ERROR: %s\n" "$*" >&2; }
fatal() { error "$@"; exit 1; }

# Parameter environment variables
swift_sdk_directory="${SWIFT_SDK_DIRECTORY:-"/tmp/swiftsdks"}"

log "Using Swift SDK directory: $swift_sdk_directory"

# Select the Swift SDK for Android
SWIFT_SDK="$(swift sdk list --swift-sdks-path "$swift_sdk_directory" | grep android | head -n1)"
if [[ -z "$SWIFT_SDK" ]]; then
  fatal "No Android Swift SDK found. Please ensure you have the Android Swift SDK installed."
fi

log "Building using Swift SDK: $SWIFT_SDK"
swift build --swift-sdk "$SWIFT_SDK" --swift-sdks-path "$swift_sdk_directory" --static-swift-stdlib "${@}"
