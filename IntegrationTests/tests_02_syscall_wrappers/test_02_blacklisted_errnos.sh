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
#if os(macOS) || os(tvOS) || os(iOS) || os(watchOS)
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
var whatevs: UInt8 = 123
_ = try? withUnsafePointer(to: &whatevs) { ptr in
    print("makeEBADFHappen? \(makeEBADFHappen ? "YES" : "NO")")
    print("makeEFAULTHappen ? \(makeEFAULTHappen ? "YES" : "NO")")
    _ = try Posix.write(descriptor: makeEBADFHappen ? -1 : fds[0],
                        pointer: makeEFAULTHappen ? UnsafePointer<UInt8>(bitPattern: 0xdeadbee)! : ptr,
                     size: 1)
}
exit(42)
EOF

make_package

for mode in debug release; do
    for error in EFAULT EBADF; do
        temp_file="$tmp/stderr"
        if "$swift_binary" run -c "$mode" -Xswiftc -DRUNNING_INTEGRATION_TESTS \
            syscallwrapper "$error" 2> "$temp_file"; then

            fail "exited successfully but was supposed to fail"
        else
            exit_code=$?
            # expecting illegal instruction as it should fail with a blacklisted errno
            if [[ "$mode" == "release" ]]; then
                assert_equal 42 $exit_code
            else
                assert_equal $(( 128 + 4 )) $exit_code  # 4 == SIGILL
                grep -q blacklisted\ errno "$temp_file"
            fi
        fi
    done
done

rm -rf "$tmpdir"
