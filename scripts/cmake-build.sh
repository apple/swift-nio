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

version="${CMAKE_VERSION:="3.31.6"}"
target_dir="${TARGET_DIRECTORY:=""}"

if [ -z "$version" ]; then
  fatal "CMake version must be specified."
fi
if [ -z "$target_dir" ]; then
  fatal "Target directory must be specified."
fi

log "Installing tools for this script"
which curl || apt update -y -q && apt install -y -q curl

log "Obtaining CMake (${CMAKE_VERSION})"
curl -sL "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-x86_64.tar.gz" -o /tmp/cmake.tar.gz

log "Installing CMake"
tar xfvz /tmp/cmake.tar.gz --strip-components 1 -C /usr/

log "Installing Ninja"
apt install -y -q ninja-build

log "Building Ninja build files for target"
build_directory="${TARGET_DIRECTORY}/build"
mkdir -p "${build_directory}"
cd "${build_directory}" || fatal "Could not 'cd' to ${build_directory}"
cmake build -G Ninja -S ..

log "Building target"
ninja
