#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) YEARS Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

set -eu

here="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
rm -f "$here"/*.swift

function nio_changes() {
    echo "/* Changes for SwiftNIO"
    echo "   - renamed Deque to NIODeque (to prevent future clashes)"
    echo "   - made (NIO)Deque internal (not public)"
    echo
    echo "  DO NOT CHANGE THESE FILES, THEY ARE VENDORED FROM Swift Collections."
    echo "*/"
}

tmpdir=$(mktemp -d /tmp/.vendor_XXXXXX)
(
set -eu

cd "$tmpdir"
git clone https://github.com/apple/swift-collections.git
)

for f in "$tmpdir"/swift-collections/Sources/DequeModule/*.swift; do
    fbn=$(basename "$f")
    { nio_changes; cat "$f"; } | \
        sed -r \
            -e 's#public (__consuming )?(static )?(mutating )?(subscript|struct|func|init|class|var|let|typealias|enum)#@usableFromInline internal /*was public */ \1\2\3\4#g' \
            -e 's/@_spi\([a-zA-Z]+\)//g' \
            -e 's#@frozen#/* was @frozen */#g' \
            -e 's#@inlinable#/* was @inlinable */#g' \
            -e 's#^  static func (==|<)#  @usableFromInline static func \1#g' \
            -e 's#Deque#NIODeque#g' \
            > "$here/$fbn"
done
