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

if command -v apt-get >/dev/null; then
  PACKAGE_MANAGER_BIN="apt-get"
  apt-get update > /dev/null
elif command -v yum >/dev/null; then
  PACKAGE_MANAGER_BIN="yum"
else
  fatal "Cannot find either 'apt' or 'yum'"
fi

log "Installing standard Swift prerequisites"  # pre-reqs list taken from swift.org
DEBIAN_FRONTEND=noninteractive "$PACKAGE_MANAGER_BIN" install -y\
    binutils\
    git\
    gnupg2\
    libc6-dev\
    libcurl4-openssl-dev\
    libedit2\
    libgcc-11-dev\
    libpython3-dev\
    libsqlite3-0\
    libstdc++-11-dev\
    libxml2-dev\
    libz3-dev\
    pkg-config\
    python3-lldb-13\
    tzdata\
    unzip\
    zlib1g-dev\
    > /dev/null
