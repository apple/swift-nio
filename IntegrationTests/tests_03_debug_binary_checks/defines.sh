#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

here="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
pushd "$here/../.." || exit
swift build
# shellcheck disable=SC2034 # Used by imports
bin_path=$(swift build --show-bin-path)
popd || exit
