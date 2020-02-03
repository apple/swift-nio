#!/usr/bin/env python
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

import sys
import re

num_regex = "^ +([0-9a-fx]+)$"
stack_regex = "^ +(.*)$"

def put_in_dict(path):
    dictionary = {}
    with open(path, "r") as f:
        current_text = ""
        for line in f:
            if line == "":
                break
            if re.match(num_regex, line):
                key = "\n".join(map(lambda l: l.strip().split("+")[0],
                                    current_text.split("\n")[0:8]))
                dictionary[key] = (int(line), current_text)
                current_text = ""
            elif line.strip() == "":
                pass
            else:
                current_text = current_text + line.strip() + "\n"
    return dictionary

def extract_useful_keys(d):
    keys = set()
    for k in d.keys():
        if d[k][0] > 1000:
            keys.add(k)
    return keys

def usage():
    print("Usage: stackdiff-dtrace.py OLD-STACKS NEW-STACKS")
    print()
    print("stackdiff-dtrace can diff aggregated stack traces as produced")
    print("by a `agg[ustack()] = count();` and printed with `printa(agg)`;")
    print("by a dtrace program.")
    print()
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

after_dict = put_in_dict(before_file)
before_dict = put_in_dict(after_file)

useful_after_keys = extract_useful_keys(after_dict)
useful_before_keys = extract_useful_keys(before_dict)

print("")
print("### only in AFTER")
for x in sorted(list(useful_after_keys - useful_before_keys)):
    print(after_dict[x][0])
    print(after_dict[x][1])

print("")
print("### only in BEFORE")
for x in sorted(list(useful_before_keys - useful_after_keys)):
    print(before_dict[x][0])
    print(before_dict[x][1])

print("")
print("### different numbers")
for x in sorted(list(useful_before_keys & useful_after_keys)):
    if after_dict[x][0] != before_dict[x][0]:
        print("before: %d, after: %d" % (before_dict[x][0],
                                         after_dict[x][0]))
        print(after_dict[x][1])
