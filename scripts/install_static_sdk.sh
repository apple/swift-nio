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
branch="${INSTALL_SWIFT_STATIC_SDK_BRANCH:=""}"
version="${INSTALL_SWIFT_STATIC_SDK_VERSION:=""}"
arch="${INSTALL_SWIFT_STATIC_SDK_ARCH:="aarch64"}"
os_image="${INSTALL_SWIFT_STATIC_SDK_OS_IMAGE:="ubuntu22.04"}"

if [[ ! ( -n "$branch" && -z "$version" ) && ! ( -z "$branch" && -n "$version") ]]; then
  fatal "Exactly one of build or version must be defined."
fi

CURL_BIN="${CURL_BIN:-$(which curl 2> /dev/null)}"; test -n "$CURL_BIN" || fatal "CURL_BIN unset and no curl on PATH"
TAR_BIN="${TAR_BIN:-$(which tar 2> /dev/null)}"; test -n "$TAR_BIN" || fatal "TAR_BIN unset and no tar on PATH"
JQ_BIN="${JQ_BIN:-$(which jq 2> /dev/null)}"; test -n "$JQ_BIN" || fatal "JQ_BIN unset and no jq on PATH"
SED_BIN="${SED_BIN:-$(which sed 2> /dev/null)}"; test -n "$SED_BIN" || fatal "SED_BIN unset and no sed on PATH"

case "$arch" in
  "aarch64")
    arch_suffix="-$arch" ;;
  "x86_64")
    arch_suffix="" ;;
  *)
    fatal "Unexpected architecture: $arch" ;;
esac

os_image_sanitized="${os_image//./}"

if [[ -n "$branch" ]]; then
  # Some snapshots may not have all the artefacts we require
  log "Discovering branch snapshot for branch $branch"

  # shellcheck disable=SC2016  # Our use of JQ_BIN means that shellcheck can't tell this is a `jq` invocation
  snapshots="$("$CURL_BIN" -s "https://www.swift.org/api/v1/install/dev/main/${os_image_sanitized}.json" | "$JQ_BIN" -r --arg arch "$arch" '.[$arch] | unique | reverse | .[].dir')"

  for snapshot in $snapshots; do
    snapshot_url="https://download.swift.org/development/${os_image_sanitized}${arch_suffix}/${snapshot}/${snapshot}-${os_image}${arch_suffix}.tar.gz"
    static_sdk_url="https://download.swift.org/development/static-sdk/${snapshot}/${snapshot}_static-linux-0.0.1.artifactbundle.tar.gz"
    
    # check that the files exist
    "$CURL_BIN" -sILXGET --fail "$snapshot_url" > /dev/null; snapshot_return_code=$?
    "$CURL_BIN" -sILXGET --fail "$static_sdk_url" > /dev/null; static_sdk_return_code=$?
    
    if [[ ("$snapshot_return_code" -eq 0) && ("$static_sdk_return_code" -eq 0) ]]; then
      log "Discovered branch snapshot: $snapshot"
      break
    else
      log "Snapshot unavailable: $snapshot (Snapshot return code: $snapshot_return_code, Static SDK return code: $static_sdk_return_code)"
      snapshot=""
    fi
  done
  if [[ -z "$snapshot" ]]; then
    fatal "Failed to discover usable Swift snapshot"
  fi
  
elif [[ -n "$version" ]]; then
  if [[ "$version" == "latest" ]]; then
    log "Discovering latest version"
    version=$("$CURL_BIN" -s https://www.swift.org/api/v1/install/releases.json | "$JQ_BIN" -r '.[-1].tag' | "$SED_BIN" -E 's/swift-([0-9]+\.[0-9]+\.?[0-9]*)-RELEASE/\1/')
    if [[ -z "$version" ]]; then
      fatal "Failed to discover latest Swift version"
    fi
    log "Discovered latest Swift version: $version"
  fi

  snapshot_url="https://download.swift.org/swift-${version}-release/${os_image_sanitized}${arch_suffix}/swift-${version}-RELEASE/swift-${version}-RELEASE-${os_image}${arch_suffix}.tar.gz"
  static_sdk_url="https://download.swift.org/swift-${version}-release/static-sdk/swift-${version}-RELEASE/swift-${version}-RELEASE_static-linux-0.0.1.artifactbundle.tar.gz"
fi

log "Obtaining Swift toolchain"
log "Snapshot URL: $snapshot_url"
snapshot_path="/tmp/$(basename "$snapshot_url")"
"$CURL_BIN" -sfL "$snapshot_url" -o "$snapshot_path" || fatal "Failed to download Swift toolchain"

log "Installing Swift toolchain"
mkdir -p /tmp/snapshot
"$TAR_BIN" xfz "$snapshot_path" --strip-components 1 -C /

log "Obtaining Static SDK"
log "Static SDK URL: $static_sdk_url"
static_sdk_path="/tmp/$(basename "$static_sdk_url")"
"$CURL_BIN" -sfL "$static_sdk_url" -o "$static_sdk_path" || fatal "Failed to download Static SDK"

log "Looking for swift"
which swift || fatal "Failed to locate installed Swift"

log "Checking swift"
swift --version

log "Installing Static SDK"
swift sdk install "$static_sdk_path"
