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

# shellcheck source=IntegrationTests/tests_01_http/defines.sh
source defines.sh

set -eu
here="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

test -n "${SWIFT_VERSION:-}" || fatal "SWIFT_VERSION unset"

all_tests=()
for file in "$here/test_01_resources/"test_*.swift; do
    test_name=$(basename "$file")
    test_name=${test_name#test_*}
    test_name=${test_name%*.swift}
    all_tests+=( "$test_name" )
done

"$here/test_01_resources/run-nio-alloc-counter-tests.sh" -t "$tmp" > "$tmp/output"

observed_allocations="{"
for test in "${all_tests[@]}"; do
    while read -r test_case; do
        test_case=${test_case#test_*}
        total_allocations=$(grep "^test_$test_case.total_allocations:" "$tmp/output" | cut -d: -f2 | sed 's/ //g')
        observed_allocations="${observed_allocations}
    \"${test_case}\": ${total_allocations},"
    done < <(grep "^test_${test}[^\W]*.total_allocations:" "$tmp/output" | cut -d: -f1 | cut -d. -f1 | sort | uniq)
done
observed_allocations="${observed_allocations}
}"
info "observed allocations:
${observed_allocations}"

for test in "${all_tests[@]}"; do
    cat "$tmp/output"  # helps debugging

    while read -r test_case; do
        test_case=${test_case#test_*}
        total_allocations=$(grep "^test_$test_case.total_allocations:" "$tmp/output" | cut -d: -f2 | sed 's/ //g')
        not_freed_allocations=$(grep "^test_$test_case.remaining_allocations:" "$tmp/output" | cut -d: -f2 | sed 's/ //g')
        leaked_fds=$(grep "^test_$test_case.leaked_fds:" "$tmp/output" | cut -d: -f2 | sed 's/ //g')
        max_allowed_env_name="MAX_ALLOCS_ALLOWED_$test_case"
        max_allowed=$(jq '.'\""$test_case"\" "$here/Thresholds/$SWIFT_VERSION.json")
        
        assert_is_number "$max_allowed" "Malformed or nonexistent ${SWIFT_VERSION}.json thresholds file"

        info "$test_case: allocations not freed: $not_freed_allocations"
        info "$test_case: total number of mallocs: $total_allocations"
        info "$test_case: leaked fds: $leaked_fds"

        assert_less_than "$not_freed_allocations" 5 "Allocations not freed are greater than expected"     # allow some slack
        assert_greater_than "$not_freed_allocations" -5 "Allocations not freed are less than expected" # allow some slack
        assert_less_than "$leaked_fds" 1 "There are leaked file descriptors" # No slack allowed here though
        if [[ -z "${!max_allowed_env_name+x}" ]] && [ -z "${max_allowed}" ]; then
            if [[ -z "${!max_allowed_env_name+x}" ]]; then
                warn "no reference number of allocations set (set to \$$max_allowed_env_name)"
                warn "to set current number either:"
                warn "    export $max_allowed_env_name=$total_allocations"
                warn "    or set them in the Swift version specific threshold json"
            fi
        else
            if [ -z "${max_allowed}" ]; then
                max_allowed=${!max_allowed_env_name}
            fi
            assert_less_than_or_equal "$total_allocations" "$max_allowed" "Total allocations exceed the max allowed"
            assert_greater_than "$total_allocations" "$(( max_allowed - 1000))" "Total allocations are less than expected"
        fi
    done < <(grep "^test_${test}[^\W]*.total_allocations:" "$tmp/output" | cut -d: -f1 | cut -d. -f1 | sort | uniq)
done
