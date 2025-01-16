#!/usr/bin/env python3
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

import collections
import re
import sys

num_regex = b"^ +([0-9]+)$"


def put_in_dict(path):
    # Our input looks something like:
    #
    # =====
    # This will collect stack shots of allocations and print it when you exit dtrace.
    # So go ahead, run your tests and then press Ctrl+C in this window to see the aggregated result # noqa: E501
    # =====
    # DEBUG: After waiting 1 times, we quiesced to unfreeds=744
    # test_1_reqs_1000_conn.total_allocations: 490000
    # test_1_reqs_1000_conn.total_allocated_bytes: 42153000
    # test_1_reqs_1000_conn.remaining_allocations: 0
    # DEBUG: [["total_allocations": 490000, "total_allocated_bytes": 42153000, ...
    #
    # (truncated)
    #
    #               libsystem_malloc.dylib`malloc_zone_malloc
    #               libswiftCore.dylib`swift_slowAlloc+0x28
    #               libswiftCore.dylib`swift_allocObject+0x27
    #               test_1_reqs_1000_conn`closure #3 in SelectableEventLoop.run()+0x166
    #               test_1_reqs_1000_conn`SelectableEventLoop.run()+0x234
    #               test_1_reqs_1000_conn`closure #1 in static MultiThreadedEventLoopGroup.setupThreadAndEventLoop(name:selectorFactory:initializer:)+0x12e # noqa: E501
    #               test_1_reqs_1000_conn`partial apply for closure #1 in static MultiThreadedEventLoopGroup.setupThreadAndEventLoop(name:selectorFactory:initializer:)+0x25 # noqa: E501
    #               test_1_reqs_1000_conn`thunk for @escaping @callee_guaranteed (@guaranteed NIOThread) -> ()+0xf # noqa: E501
    #               test_1_reqs_1000_conn`partial apply for thunk for @escaping @callee_guaranteed (@guaranteed NIOThread) -> ()+0x11 # noqa: E501
    #               test_1_reqs_1000_conn`closure #1 in static ThreadOpsPosix.run(handle:args:detachThread:)+0x1c9 # noqa: E501
    #               libsystem_pthread.dylib`_pthread_start+0xe0
    #               libsystem_pthread.dylib`thread_start+0xf
    #             85945
    #
    #               libsystem_malloc.dylib`malloc_zone_malloc
    #               libswiftCore.dylib`swift_slowAlloc+0x28
    #               libswiftCore.dylib`swift_allocObject+0x27
    # (truncated)
    dictionary = collections.defaultdict(list)
    with open(path, "rb") as f:
        current_stack = []
        for line in f:
            if not line.startswith(b" "):
                # All lines we're intereted in are indented so ignore this one.
                pass
            elif re.match(num_regex, line):
                # The line contains just a number. This must be the end of a
                # stack, i.e. the number of allocations.

                # Build a key for the current stack. Each line looks
                # like: 'libswiftCore.dylib`swift_allocObject+0x27'. We want
                # everything before the '+'. We only take at most the first 8
                # lines for the key so that we group 'similar' stacks in our
                # output.
                key = b"\n".join(line.split(b"+")[0] for line in current_stack[:8])

                # Record this stack and reset our state to build a new one.
                dictionary[key].append((int(line), b"\n".join(current_stack)))
                current_stack = []
            else:
                # This line doesn't contain just a number. This might be an
                # entry in the current stack.
                stripped = line.strip()
                if stripped != "":
                    current_stack.append(stripped)

    return dictionary


def total_count_for_key(d, key):
    value = d[key]
    return sum(map(lambda x: x[0], value))


def total_for_dictionary(d):
    total = 0
    for k in d.keys():
        total += total_count_for_key(d, k)
    return total


def extract_useful_keys(d):
    keys = set()
    for k in d.keys():
        if total_count_for_key(d, k) >= 1000:
            keys.add(k)
    return keys


def print_dictionary_member(d, key):
    print(total_count_for_key(d, key))
    print(key.decode('utf8'))
    print()
    print_dictionary_member_detail(d, key)
    print()


def print_dictionary_member_detail(d, key):
    value = d[key]
    for (count, stack) in value:
        print("    %d" % count)
        print((b"        " + stack.replace(b"\n", b"\n        ")).decode('utf8'))


def usage():
    print("Usage: stackdiff-dtrace.py OLD-STACKS NEW-STACKS")
    print("")
    print("stackdiff-dtrace can diff aggregated stack traces as produced")
    print("by a `agg[ustack()] = count();` and printed with `printa(agg)`;")
    print("by a dtrace program.")
    print("")
    print("Full example leveraging the malloc aggregation:")
    print("  # get old stack traces")
    print("  sudo malloc-aggregation.d -c ./old-binary > /tmp/old")
    print("  # get new stack traces")
    print("  sudo malloc-aggregation.d -c ./new-binary > /tmp/new")
    print("  # diff them")
    print("  stackdiff-dtrace.py /tmp/old /tmp/new")


if len(sys.argv) != 3:
    usage()
    sys.exit(1)

before_file = sys.argv[1]
after_file = sys.argv[2]

after_dict = put_in_dict(after_file)
before_dict = put_in_dict(before_file)

useful_after_keys = extract_useful_keys(after_dict)
useful_before_keys = extract_useful_keys(before_dict)

print("")
print("### only in AFTER")
only_after_total = 0
for x in sorted(list(useful_after_keys - useful_before_keys)):
    print_dictionary_member(after_dict, x)
    only_after_total += total_count_for_key(after_dict, x)
print("Total for only in AFTER:  %d" % only_after_total)

print("")
print("### only in BEFORE")
only_before_total = 0
for x in sorted(list(useful_before_keys - useful_after_keys)):
    print_dictionary_member(before_dict, x)
    only_before_total += total_count_for_key(before_dict, x)
print("Total for only in BEFORE:  %d" % only_before_total)

print("")
print("### different numbers")
for x in sorted(list(useful_before_keys & useful_after_keys)):
    before_count = total_count_for_key(before_dict, x)
    after_count = total_count_for_key(after_dict, x)
    if before_count != after_count:
        print("before: %d, after: %d" % (before_count,
                                         after_count))
        print("  AFTER")
        print_dictionary_member_detail(after_dict, x)
        print("  BEFORE")
        print_dictionary_member_detail(before_dict, x)
        print()

everything_before = total_for_dictionary(before_dict)
everything_after = total_for_dictionary(after_dict)
print("Total of _EVERYTHING_ BEFORE:  %d,  AFTER:  %d,  DIFFERENCE:  %d" % (everything_before, everything_after, everything_after - everything_before))  # noqa: E501
