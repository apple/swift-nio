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
branch="${INSTALL_SWIFT_BRANCH:-""}"
version="${INSTALL_SWIFT_VERSION:-""}"
arch="${INSTALL_SWIFT_ARCH:-"aarch64"}"
os_image="${INSTALL_SWIFT_OS_IMAGE:-"ubuntu22.04"}"
sdk="${INSTALL_SWIFT_SDK:-"static-sdk"}"
swift_sdk_directory="${SWIFT_SDK_DIRECTORY:-"/tmp/swiftsdks"}"

if [[ ! ( -n "$branch" && -z "$version" ) && ! ( -z "$branch" && -n "$version") ]]; then
  fatal "Exactly one of build or version must be defined."
fi

CURL_BIN="${CURL_BIN:-$(which curl 2> /dev/null)}"; test -n "$CURL_BIN" || fatal "CURL_BIN unset and no curl on PATH"
TAR_BIN="${TAR_BIN:-$(which tar 2> /dev/null)}"; test -n "$TAR_BIN" || fatal "TAR_BIN unset and no tar on PATH"
JQ_BIN="${JQ_BIN:-$(which jq 2> /dev/null)}"; test -n "$JQ_BIN" || fatal "JQ_BIN unset and no jq on PATH"
SED_BIN="${SED_BIN:-$(which sed 2> /dev/null)}"; test -n "$SED_BIN" || fatal "SED_BIN unset and no sed on PATH"
SHASUM_BIN="${SHASUM_BIN:-$(which shasum 2> /dev/null)}"; test -n "$SHASUM_BIN" || fatal "SHASUM_BIN unset and no shasum on PATH"
GPG_BIN="${GPG_BIN:-$(which gpg 2> /dev/null)}"; test -n "$GPG_BIN" || fatal "GPG_BIN unset and no gpg on PATH"
ZCAT_BIN="${ZCAT_BIN:-$(which zcat 2> /dev/null)}"; test -n "$ZCAT_BIN" || fatal "ZCAT_BIN unset and no zcat on PATH"

case "$arch" in
  "aarch64")
    arch_suffix="-$arch" ;;
  "x86_64")
    arch_suffix="" ;;
  *)
    fatal "Unexpected architecture: $arch" ;;
esac

case "$sdk" in
  "static-sdk")
    sdk_dir="static-sdk"
    sdk_suffix="_static-linux-0.0.1"
    ;;
  "wasm-sdk")
    sdk_dir="wasm-sdk"
    sdk_suffix="_wasm"
    ;;
  "android-sdk")
    sdk_dir="android-sdk"
    sdk_suffix="_android-0.1"
    ;;
  *)
    fatal "Unexpected Swift SDK: $sdk"
    ;;
esac

os_image_sanitized="${os_image//./}"

# Function to extract checksum from release info
extract_checksum() {
  local release_info="$1"
  if [[ -z "$release_info" ]]; then
    log "Warning: No release information available"
    return
  fi

  local checksum
  # shellcheck disable=SC2016  # Our use of JQ_BIN means that shellcheck can't tell this is a `jq` invocation
  checksum=$(echo "$release_info" | "$JQ_BIN" -r --arg platform "$sdk" '.platforms[] | select(.platform == $platform) | .checksum // empty')
  if [[ -n "$checksum" ]]; then
    log "Found checksum for $sdk: $checksum"
    echo "$checksum"
  else
    log "Warning: No checksum available for $sdk platform"
  fi
}

if [[ -n "$branch" ]]; then
  # Some snapshots may not have all the artefacts we require
  log "Discovering branch snapshot for branch $branch"

  # shellcheck disable=SC2016  # Our use of JQ_BIN means that shellcheck can't tell this is a `jq` invocation
  snapshots="$("$CURL_BIN" -s "https://www.swift.org/api/v1/install/dev/main/${os_image_sanitized}.json" | "$JQ_BIN" -r --arg arch "$arch" '.[$arch] | unique | reverse | .[].dir')"

  for snapshot in $snapshots; do
    snapshot_url="https://download.swift.org/development/${os_image_sanitized}${arch_suffix}/${snapshot}/${snapshot}-${os_image}${arch_suffix}.tar.gz"
    sdk_url="https://download.swift.org/development/${sdk_dir}/${snapshot}/${snapshot}${sdk_suffix}.artifactbundle.tar.gz"

    # check that the files exist
    "$CURL_BIN" -sILXGET --fail "$snapshot_url" > /dev/null; snapshot_return_code=$?
    "$CURL_BIN" -sILXGET --fail "$sdk_url" > /dev/null; sdk_return_code=$?

    if [[ ("$snapshot_return_code" -eq 0) && ("$sdk_return_code" -eq 0) ]]; then
      log "Discovered branch snapshot: $snapshot"
      break
    else
      log "Snapshot unavailable: $snapshot (Snapshot return code: $snapshot_return_code, Swift SDK return code: $sdk_return_code)"
      snapshot=""
    fi
  done
  if [[ -z "$snapshot" ]]; then
    fatal "Failed to discover usable Swift snapshot"
  fi

elif [[ -n "$version" ]]; then
  if [[ "$version" == "latest" ]]; then
    log "Discovering latest version"
    release_info=$("$CURL_BIN" -s https://www.swift.org/api/v1/install/releases.json | "$JQ_BIN" -r '.[-1]')
    if [[ -z "$release_info" ]]; then
      log "Warning: Could not find release information for version $version"
    fi
    version=$(echo "$release_info" | "$JQ_BIN" -r '.tag' | "$SED_BIN" -E 's/swift-([0-9]+\.[0-9]+\.?[0-9]*)-RELEASE/\1/')
    if [[ -z "$version" ]]; then
      fatal "Failed to discover latest Swift version"
    fi
    log "Discovered latest Swift version: $version"

  else
    # For specific versions, we need to fetch the release info
    log "Getting release information for version $version"
    # shellcheck disable=SC2016  # Our use of JQ_BIN means that shellcheck can't tell this is a `jq` invocation
    release_info=$("$CURL_BIN" -s https://www.swift.org/api/v1/install/releases.json | "$JQ_BIN" -r --arg ver "swift-$version-RELEASE" '.[] | select(.tag == $ver)')
    if [[ -z "$release_info" ]]; then
      log "Warning: Could not find release information for version $version"
    fi
  fi

  expected_checksum=$(extract_checksum "$release_info")
  snapshot_url="https://download.swift.org/swift-${version}-release/${os_image_sanitized}${arch_suffix}/swift-${version}-RELEASE/swift-${version}-RELEASE-${os_image}${arch_suffix}.tar.gz"
  sdk_url="https://download.swift.org/swift-${version}-release/${sdk_dir}/swift-${version}-RELEASE/swift-${version}-RELEASE${sdk_suffix}.artifactbundle.tar.gz"
fi

log "Obtaining Swift toolchain"
log "Snapshot URL: $snapshot_url"
snapshot_path="/tmp/$(basename "$snapshot_url")"
"$CURL_BIN" -sfL "$snapshot_url" -o "$snapshot_path" || fatal "Failed to download Swift toolchain"

# Import Swift's public key for GPG verification

keys_url="https://swift.org/keys/all-keys.asc"
keys_path="/tmp/all-keys.asc"
"$CURL_BIN" -sL "$keys_url" -o "$keys_path" || fatal "Failed to download Swift's public keys"
"$ZCAT_BIN" -f "$keys_path" | "$GPG_BIN" --import - || fatal "Failed to import Swift's public keys"

# Verify GPG signature for all Swift toolchain downloads
signature_url="${snapshot_url}.sig"
signature_path="${snapshot_path}.sig"

log "Downloading signature from: $signature_url"
echo "$CURL_BIN" -sfL "$signature_url" -o "$signature_path"
"$CURL_BIN" -sfL "$signature_url" -o "$signature_path" || fatal "Failed to download Swift toolchain signature"

# Verify the signature
log "Verifying Swift toolchain GPG signature..."
"$GPG_BIN" --verify "$signature_path" "$snapshot_path" || fatal "Swift toolchain GPG signature verification failed"

# Clean up signature file
rm -f "$signature_path"

log "Installing Swift toolchain"
mkdir -p /tmp/snapshot
"$TAR_BIN" xfz "$snapshot_path" --strip-components 1 -C /

log "Obtaining Swift SDK"
log "Swift SDK URL: $sdk_url"
sdk_path="/tmp/$(basename "$sdk_url")"
"$CURL_BIN" -sfL "$sdk_url" -o "$sdk_path" || fatal "Failed to download Swift SDK"

# Verify SDK checksum if available
if [[ -n "${expected_checksum:-}" ]]; then
  log "Verifying Swift SDK checksum..."
  actual_checksum=$("$SHASUM_BIN" -a 256 "$sdk_path" | cut -d' ' -f1)
  if [[ "$actual_checksum" = "$expected_checksum" ]]; then
    log "Swift SDK checksum verified successfully"
  else
    fatal "Swift SDK checksum mismatch: expected $expected_checksum, got $actual_checksum"
  fi
else
  log "Skipping checksum verification (no checksum available)"
fi

log "Looking for swift"
which swift || fatal "Failed to locate installed Swift"

log "Checking swift"
swift --version

log "Installing Swift SDK"
log "Using Swift SDK directory: $swift_sdk_directory"
mkdir -p "$swift_sdk_directory/swift-sdks"
swift sdk install --swift-sdks-path "$swift_sdk_directory" "$sdk_path"
