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
arch="${INSTALL_SWIFT_ARCH:-"aarch64"}"

# The Android Swift SDK bundle ships one target triple per (architecture, API version)
# pair, so SwiftPM needs to be told which one to build for.
android_sdk_triple="${ANDROID_SDK_TRIPLE:-"${arch}-unknown-linux-android28"}"

log "Using Swift SDK directory: $swift_sdk_directory"

# Select the Swift SDK for Android
SWIFT_SDK="$(swift sdk list --swift-sdks-path "$swift_sdk_directory" | grep android | head -n1)"
if [[ -z "$SWIFT_SDK" ]]; then
  fatal "No Android Swift SDK found. Please ensure you have the Android Swift SDK installed."
fi

log "Building using Swift SDK: $SWIFT_SDK (triple: $android_sdk_triple)"

# Pin the native build system for now: SwiftPM now defaults to swiftbuild, whose Android
# support expects a locally installed NDK found via ANDROID_NDK_ROOT/ANDROID_NDK_HOME
# rather than the one the Swift SDK links into its sysroot.
swift build --build-system native --swift-sdk "$SWIFT_SDK" --triple "$android_sdk_triple" --swift-sdks-path "$swift_sdk_directory" "${@}"
