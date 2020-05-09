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
                values = dictionary.get(key, [])
                values.append( (int(line), current_text) )
                dictionary[key] = values
                current_text = ""
            elif line.strip() == "":
                pass
            else:
                current_text = current_text + line.strip() + "\n"
    return dictionary

def total_count_for_key(d, key):
    value = d[key]
    return sum(map(lambda x : x[0], value))

def total_for_dictionary(d):
    total = 0
    for k in d.keys():
        total += total_count_for_key(d, k)
    return total

def extract_useful_keys(d):
    keys = set()
    for k in d.keys():
        if total_count_for_key(d, k) > 1000:
            keys.add(k)
    return keys

def print_dictionary_member(d, key):
    value = d[key]
    print(total_count_for_key(d, key))
    print(key)
    print()
    for (count, stack) in value:
        print("    %d" % count)
        print("        " + stack.replace("\n", "\n        "))

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
        print(x)
        print()

everything_before = total_for_dictionary(before_dict)
everything_after = total_for_dictionary(after_dict)
print("Total of _EVERYTHING_ BEFORE:  %d,  AFTER:  %d,  DIFFERENCE:  %d" % 
    (everything_before, everything_after, everything_after - everything_before))
