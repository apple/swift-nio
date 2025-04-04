#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
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

function gen() {
    how_many=$1

    # READ
    echo "    @inlinable"
    echo "    @_alwaysEmitIntoClient"
    echo -n "    public mutating func readMultipleIntegers<T1: FixedWidthInteger"
    for n in $(seq 2 "$how_many"); do
        echo -n ", T$n: FixedWidthInteger"
    done
    echo -n ">("
    echo -n "endianness: Endianness = .big, as: (T1"
    for n in $(seq 2 "$how_many"); do
        echo -n ", T$n"
    done
    echo -n ").Type = (T1"
    for n in $(seq 2 "$how_many"); do
        echo -n ", T$n"
    done
    echo -n ").self) -> (T1"
    for n in $(seq 2 "$how_many"); do
        echo -n ", T$n"
    done
    echo ")? {"
    echo "        var bytesRequired: Int = MemoryLayout<T1>.size"
    for n in $(seq 2 "$how_many"); do
        echo "        bytesRequired &+= MemoryLayout<T$n>.size"
    done
    echo
    echo "        guard self.readableBytes >= bytesRequired else {"
    echo "            return nil"
    echo "        }"
    echo
    for n in $(seq 1 "$how_many"); do
        echo "        var v$n: T$n = 0"
    done
    echo "        var offset = 0"
    echo "        self.readWithUnsafeReadableBytes { ptr -> Int in"
    echo "            assert(ptr.count >= bytesRequired)"
    echo "            let basePtr = ptr.baseAddress! // safe, ptr is non-empty"
    for n in $(seq 1 "$how_many"); do
        echo "            withUnsafeMutableBytes(of: &v$n) { destPtr in"
        echo "                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T$n>.size)"
        echo "            }"
        echo "            offset = offset &+ MemoryLayout<T$n>.size"
    done
    echo "            assert(offset == bytesRequired)"
    echo "            return offset"
    echo "        }"
    echo "        switch endianness {"
    for endianness in big little; do
        echo "        case .$endianness:"
        echo -n "            return (T1(${endianness}Endian: v1)"
        for n in $(seq 2 "$how_many"); do
            echo -n ", T$n(${endianness}Endian: v$n)"
        done
        echo ")"
    done
    echo "        }"
    echo "    }"
    echo

    # PEEK
    echo "    @inlinable"
    echo "    @_alwaysEmitIntoClient"
    echo -n "    public func peekMultipleIntegers<T1: FixedWidthInteger"
    for n in $(seq 2 "$how_many"); do
        echo -n ", T$n: FixedWidthInteger"
    done
    echo -n ">("
    echo -n "endianness: Endianness = .big, as: (T1"
    for n in $(seq 2 "$how_many"); do
        echo -n ", T$n"
    done
    echo -n ").Type = (T1"
    for n in $(seq 2 "$how_many"); do
        echo -n ", T$n"
    done
    echo -n ").self) -> (T1"
    for n in $(seq 2 "$how_many"); do
        echo -n ", T$n"
    done
    echo ")? {"
    echo "        var copy = self"
    echo "        return copy.readMultipleIntegers(endianness: endianness, as: \`as\`)"
    echo "    }"
    echo

    # WRITE
    echo "    @inlinable"
    echo "    @_alwaysEmitIntoClient"
    echo "    @discardableResult"
    echo -n "    public mutating func writeMultipleIntegers<T1: FixedWidthInteger"
    for n in $(seq 2 "$how_many"); do
        echo -n ", T$n: FixedWidthInteger"
    done
    echo -n ">(_ value1: T1"
    for n in $(seq 2 "$how_many"); do
        echo -n ", _ value$n: T$n"
    done
    echo -n ", endianness: Endianness = .big, as: (T1"
    for n in $(seq 2 "$how_many"); do
        echo -n ", T$n"
    done
    echo -n ").Type = (T1"
    for n in $(seq 2 "$how_many"); do
        echo -n ", T$n"
    done
    echo ").self) -> Int {"
    for n in $(seq 1 "$how_many"); do
        echo "        var v$n: T$n"
    done
    echo "        switch endianness {"
    for endianness in .big .little; do
        echo "        case $endianness:"
        for n in $(seq 1 "$how_many"); do
            echo "            v$n = value$n${endianness}Endian"
        done
    done
    echo "        }"
    echo
    echo "        var spaceNeeded: Int = MemoryLayout<T1>.size"
    for n in $(seq 2 "$how_many"); do
        echo "        spaceNeeded &+= MemoryLayout<T$n>.size"
    done
    echo
    echo "        return self.writeWithUnsafeMutableBytes(minimumWritableBytes: spaceNeeded) { ptr -> Int in"
    echo "            assert(ptr.count >= spaceNeeded)"
    echo "            var offset = 0"
    echo "            let basePtr = ptr.baseAddress! // safe: pointer is non zero length"
    for n in $(seq 1 "$how_many"); do
        echo "            (basePtr + offset).copyMemory(from: &v$n, byteCount: MemoryLayout<T$n>.size)"
        echo "            offset = offset &+ MemoryLayout<T$n>.size"
    done
    echo "            assert(offset == spaceNeeded)"
    echo "            return offset"
    echo "        }"
    echo "    }"
    echo
}

grep -q "ByteBuffer" "${BASH_SOURCE[0]}" || {
    echo >&2 "ERROR: ${BASH_SOURCE[0]}: file or directory not found (this should be this script)"
    exit 1
}

{
cat <<"EOF"
//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// NOTE: THIS FILE IS AUTO-GENERATED BY dev/generate-bytebuffer-multi-int.sh
EOF
echo

echo "extension ByteBuffer {"

# note:
# - widening the inverval below (eg. going from {2..15} to {2..25}) is Semver minor
# - narrowing the interval below is SemVer _MAJOR_!
for n in {2..15}; do
    gen "$n"
done
echo "}"
} > "$here/../Sources/NIOCore/ByteBuffer-multi-int.swift"
