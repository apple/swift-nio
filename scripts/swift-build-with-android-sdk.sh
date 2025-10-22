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

# Select the Swift SDK for Android
SWIFT_SDK="$(swift sdk list | grep android | head -n1)"
if [[ -z "$SWIFT_SDK" ]]; then
  echo "No Android Swift SDK found. Please ensure you have the Android Swift SDK installed."
  exit 1
fi

echo "Using Swift SDK: $SWIFT_SDK"
swift build --swift-sdk "$SWIFT_SDK" "${@}"
