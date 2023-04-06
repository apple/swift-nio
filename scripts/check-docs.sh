#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

set -eu

raw_targets=$(sed -E -n -e 's/^.* - documentation_targets: \[(.*)\].*$/\1/p' .spi.yml)
targets=(${raw_targets//,/ })

for target in "${targets[@]}"; do
  swift package plugin generate-documentation --target "$target" --warnings-as-errors --analyze --level detailed
done
