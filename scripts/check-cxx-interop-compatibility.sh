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
echo "package.dependencies.append(.package(path: \"$source_dir\"))" >> Package.swift

for product in $library_products; do
  echo "package.targets.first!.dependencies.append(.product(name: \"$product\", package: \"$package_name\"))" >> Package.swift
  echo "import $product" >> "$source_file"
done

# A platform independent (but brittle) way to add the swift settings block
sed '/name: "'"${project_name}"'")/a\
        swiftSettings: [\
            .interoperabilityMode(.Cxx)\
        ]),\
' Package.swift >| Package.swift.new && mv -f Package.swift.new Package.swift
sed  's/name: "'"${project_name}"'")/name: "'"${project_name}"'"/' Package.swift >| Package.swift.new && mv -f Package.swift.new Package.swift

if ! grep -q interoperabilityMode Package.swift; then
  cat Package.swift
  fatal "Package.swift modification failed"
fi

swift build

log "✅ Passed the Cxx interoperability tests."
