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

set -uo pipefail

log() { printf -- "** %s\n" "$*" >&2; }
error() { printf -- "** ERROR: %s\n" "$*" >&2; }
fatal() { error "$@"; exit 1; }

# Parameter environment variables
# see https://developer.android.com/ndk/downloads for releases and shasums
android_ndk_version="${INSTALL_ANDROID_NDK:-"r27d"}"
android_ndk_sha1="${ANDROID_NDK_SHA1:-"22105e410cf29afcf163760cc95522b9fb981121"}"
swift_sdk_directory="${SWIFT_SDK_DIRECTORY:-"/tmp/swiftsdks"}"

CURL_BIN="${CURL_BIN:-$(which curl 2> /dev/null)}"; test -n "$CURL_BIN" || fatal "CURL_BIN unset and no curl on PATH"
UNZIP_BIN="${UNZIP_BIN:-$(which unzip 2> /dev/null)}"; test -n "$UNZIP_BIN" || fatal "UNZIP_BIN unset and no unzip on PATH"
SHASUM_BIN="${SHASUM_BIN:-$(which shasum 2> /dev/null)}"; test -n "$SHASUM_BIN" || fatal "SHASUM_BIN unset and no shasum on PATH"

# download and link the NDK
android_ndk_url="https://dl.google.com/android/repository/android-ndk-${android_ndk_version}-$(uname -s).zip"

log "Android Native Development Kit URL: $android_ndk_url"
"$CURL_BIN" -fsSL -o android_ndk.zip --retry 3 "$android_ndk_url"

# Verify checksum
log "Verifying Android NDK checksum..."
actual_sha1="$("$SHASUM_BIN" -a 1 android_ndk.zip | cut -d' ' -f1)"
test "$actual_sha1" = "$android_ndk_sha1" || fatal "Android NDK checksum mismatch: expected $android_ndk_sha1, got $actual_sha1"

"$UNZIP_BIN" -d "$swift_sdk_directory" -q android_ndk.zip
bundledir="$(find "$swift_sdk_directory"  -maxdepth 2 -type d -name '*android*.artifactbundle' | head -n 1)"
test -n "$bundledir" || fatal "Could not find Android artifact bundle directory (expected '*android*.artifactbundle')"

export ANDROID_NDK_HOME="${swift_sdk_directory}/android-ndk-${android_ndk_version}"
"${bundledir}/swift-android/scripts/setup-android-sdk.sh"
