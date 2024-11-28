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

set -euo pipefail

log() { printf -- "** %s\n" "$*" >&2; }
error() { printf -- "** ERROR: %s\n" "$*" >&2; }
fatal() { error "$@"; exit 1; }

log "Checking for Cxx interoperability compatibility..."

source_dir=$(pwd)
working_dir=$(mktemp -d)
project_name=$(basename "$working_dir")
source_file=Sources/$project_name/$(echo "$project_name" | tr . _).swift
library_products=$( swift package dump-package | jq -r '.products[] | select(.type.library != null) | .name')
package_name=$(swift package dump-package | jq -r '.name')

cd "$working_dir"
swift package init

{
  echo "let swiftSettings: [SwiftSetting] = [.interoperabilityMode(.Cxx)]"
  echo "for target in package.targets { target.swiftSettings = (target.swiftSettings ?? []) + swiftSettings }"
} >> Package.swift

echo "package.dependencies.append(.package(path: \"$source_dir\"))" >> Package.swift

for product in $library_products; do
  echo "package.targets.first!.dependencies.append(.product(name: \"$product\", package: \"$package_name\"))" >> Package.swift
  echo "import $product" >> "$source_file"
done

swift build

log "✅ Passed the Cxx interoperability tests."
