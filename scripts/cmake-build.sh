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

target_dir="${TARGET_DIRECTORY:=""}"

if [ -z "$target_dir" ]; then
  fatal "Target directory must be specified."
fi

CURL_BIN="${CURL_BIN:-$(which curl)}" || fatal "CURL_BIN unset and no curl on PATH"
TAR_BIN="${TAR_BIN:-$(which tar)}" || fatal "TAR_BIN unset and no tar on PATH"
CMAKE_BIN="${CMAKE_BIN:-$(which cmake)}" || fatal "CMAKE_BIN unset and no cmake on PATH"
NINJA_BIN="${NINJA_BIN:-$(which ninja)}" || fatal "NINJA_BIN unset and no ninja on PATH"
ASSEMBLY_COMPILER_BIN="${ASSEMBLY_COMPILER_BIN:-$(which clang)}" || fatal "ASSEMBLY_COMPILER_BIN unset and no clang on PATH"

log "Building Ninja build files for target"
build_dir="${target_dir}/build"
mkdir -p "$build_dir"
cd "${build_dir}" || fatal "Could not 'cd' to ${build_dir}"
ASM="$ASSEMBLY_COMPILER_BIN" "$CMAKE_BIN" build -G Ninja -S ..

log "Building target"
"$NINJA_BIN"
