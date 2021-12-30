#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2017-2022 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

set -eu

source defines.sh

swift_binary=swift
here="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [[ ! -z "${SWIFT_EXEC-}" ]]; then
    swift_binary="$(dirname "$SWIFT_EXEC")/swift"
elif [[ "$(uname -s)" == "Linux" ]]; then
    swift_binary=$(which swift)
fi

tmpdir=$(mktemp -d /tmp/.swift-nio-syscall-wrappers-sh-test_XXXXXX)
mkdir "$tmpdir/syscallwrapper"
cd "$tmpdir/syscallwrapper"
swift package init --type=executable
cat > "$tmpdir/syscallwrapper/Sources/syscallwrapper/main.swift" <<EOF
#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import Darwin
#else
import Glibc
#endif
public typealias IOVector = iovec


var fds: [Int32] = [-1, -1]
let pipeErr = pipe(&fds)
if pipeErr != 0 {
    // this program is expected to fail in correct operation
    exit(0)
}
let makeEBADFHappen =  CommandLine.arguments.dropFirst().first == .some("EBADF")
let makeEFAULTHappen = CommandLine.arguments.dropFirst().first == .some("EFAULT")
let makeEINVALHappen = CommandLine.arguments.dropFirst().first == .some("EINVAL")
var whatevs: UInt8 = 123
_ = try? withUnsafeMutablePointer(to: &whatevs) { ptr in
    _ = try Posix.write(
        descriptor: fds[0],
        pointer: ptr,
        size: 1
    )
    print("makeEBADFHappen? \(makeEBADFHappen ? "YES" : "NO")")
    print("makeEFAULTHappen ? \(makeEFAULTHappen ? "YES" : "NO")")
    print("makeEINVALHappen ? \(makeEINVALHappen ? "YES" : "NO")")

    let pointer: UnsafeMutablePointer<UInt8>
    if makeEFAULTHappen {
        pointer = UnsafeMutablePointer<UInt8>(bitPattern: 0xdeadbee)!
    } else if makeEINVALHappen {
        pointer = UnsafeMutablePointer<UInt8>(bitPattern: -1)!
    } else {
        pointer = ptr
    }
    _ = try Posix.read(
        descriptor: makeEBADFHappen ? -1 : fds[0],
        pointer: pointer,
        size: 1
    )
}
exit(42)
EOF

make_package

for mode in debug release; do
    for error in EFAULT EBADF EINVAL; do
        temp_file="$tmp/stderr"
        if "$swift_binary" run -c "$mode" -Xswiftc -DRUNNING_INTEGRATION_TESTS \
            syscallwrapper "$error" 2> "$temp_file"; then

            fail "exited successfully but was supposed to fail"
        else
            exit_code=$?
            # expecting illegal instruction as it should fail with an unacceptable errno
            assert_equal $(( 128 + 4 )) $exit_code  # 4 == SIGILL
            if [[ "$mode" == "debug" ]]; then
                grep -q unacceptable\ errno "$temp_file"
            fi
        fi
    done
done

rm -rf "$tmpdir"
