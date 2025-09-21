#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

set -eu

log() { printf -- "** %s\n" "$*" >&2; }
error() { printf -- "** ERROR: %s\n" "$*" >&2; }
fatal() { error "$@"; exit 1; }

config="${CONFIG_JSON:=""}"
fail_on_changes="${FAIL_ON_CHANGES:="false"}"

if [ -z "$config" ]; then
  fatal "Configuration must be provided."
fi

here=$(pwd)

case "$(uname -s)" in
    Darwin)
        find=gfind # brew install findutils
        ;;
    *)
        find='find'
        ;;
esac

function update_cmakelists_source() {
    src_root="$here/Sources/$1"

    src_exts=("*.c" "*.swift" "*.cc")
    num_exts=${#src_exts[@]}
    log "Finding source files (" "${src_exts[@]}" ") and platform independent assembly files under $src_root"

    # Build file extensions argument for `find`
    declare -a exts_arg
    exts_arg+=(-name "${src_exts[0]}")
    for (( i=1; i<num_exts; i++ ));
    do
        exts_arg+=(-o -name "${src_exts[$i]}")
    done

    # Build an array with the rest of the arguments
    shift
    exceptions=("$@")
    # Add path exceptions for `find`
    if (( ${#exceptions[@]} )); then
        log "Excluding source paths (" "${exceptions[@]}" ") under $src_root"
        num_exceptions=${#exceptions[@]}
        for (( i=0; i<num_exceptions; i++ ));
        do
            exts_arg+=(! -path "${exceptions[$i]}")
        done
    fi

    # Wrap quotes around each filename since it might contain spaces
    srcs=$($find -L "${src_root}" -type f \( "${exts_arg[@]}" \) -printf '  "%P"\n' | LC_ALL=POSIX sort)
    asm_srcs=$($find -L "${src_root}" -type f \( \( -name "*.S" -a ! -name "*x86_64*" -a ! -name "*arm*" -a ! -name "*apple*" -a ! -name "*linux*" \) \) -printf '  "$<$<NOT:$<PLATFORM_ID:Windows>>:%P>"\n' | LC_ALL=POSIX sort)

    srcs="$srcs"$'\n'"$asm_srcs"
    log "$srcs"

    # Update list of source files in CMakeLists.txt
    # The first part in `BEGIN` (i.e., `undef $/;`) is for working with multi-line;
    # the second is so that we can pass in a variable to replace with.
    perl -pi -e 'BEGIN { undef $/; $replace = shift } s/add_library\(([^\n]+)\n([^\)]+)/add_library\($1\n$replace/' "$srcs" "$src_root/CMakeLists.txt"
    log "Updated $src_root/CMakeLists.txt"
}

function update_cmakelists_assembly() {
    src_root="$here/Sources/$1"
    log "Finding assembly files (.S) under $src_root"

    mac_x86_64_asms=$($find "${src_root}" -type f \( -name "*x86_64*" -or -name "*avx2*" \) -name "*apple*" -name "*.S" -printf '    %P\n' | LC_ALL=POSIX sort)
    linux_x86_64_asms=$($find "${src_root}" -type f \( -name "*x86_64*" -or -name "*avx2*" \) -name "*linux*" -name "*.S" -printf '    %P\n' | LC_ALL=POSIX sort)
    win_x86_64_asms=$($find "${src_root}" -type f \( -name "*x86_64*" -or -name "*avx2*" \) -name "*win*" -name "*.S" -printf '    %P\n' | LC_ALL=POSIX sort)
    mac_aarch64_asms=$($find "${src_root}" -type f -name "*armv8*" -name "*apple*" -name "*.S" -printf '    %P\n' | LC_ALL=POSIX sort)
    linux_aarch64_asms=$($find "${src_root}" -type f -name "*armv8*" -name "*linux*" -name "*.S" -printf '    %P\n' | LC_ALL=POSIX sort)
    win_aarch64_asms=$($find "${src_root}" -type f -name "*armv8*" -name "*win*" -name "*.S" -printf '    %P\n' | LC_ALL=POSIX sort)
    log "$mac_x86_64_asms"
    log "$linux_x86_64_asms"
    log "$win_x86_64_asms"
    log "$mac_aarch64_asms"
    log "$linux_aarch64_asms"
    log "$win_aarch64_asms"

    # Update list of assembly files in CMakeLists.txt
    # The first part in `BEGIN` (i.e., `undef $/;`) is for working with multi-line;
    # the second is so that we can pass in a variable to replace with.
    perl -pi -e 'BEGIN { undef $/; $replace = shift } s/Darwin([^\)]+)x86_64"\)\n  target_sources\(([^\n]+)\n([^\)]+)/Darwin$1x86_64"\)\n  target_sources\($2\n$replace/' "$mac_x86_64_asms" "$src_root/CMakeLists.txt"
    perl -pi -e 'BEGIN { undef $/; $replace = shift } s/Linux([^\)]+)x86_64"\)\n  target_sources\(([^\n]+)\n([^\)]+)/Linux$1x86_64"\)\n  target_sources\($2\n$replace/' "$linux_x86_64_asms" "$src_root/CMakeLists.txt"
    perl -pi -e 'BEGIN { undef $/; $replace = shift } s/Windows([^\)]+)x86_64"\)\n  target_sources\(([^\n]+)\n([^\)]+)/Windows$1x86_64"\)\n  target_sources\($2\n$replace/' "$win_x86_64_asms" "$src_root/CMakeLists.txt"
    perl -pi -e 'BEGIN { undef $/; $replace = shift } s/Darwin([^\)]+)aarch64"\)\n  target_sources\(([^\n]+)\n([^\)]+)/Darwin$1aarch64"\)\n  target_sources\($2\n$replace/' "$mac_aarch64_asms" "$src_root/CMakeLists.txt"
    perl -pi -e 'BEGIN { undef $/; $replace = shift } s/Linux([^\)]+)aarch64"\)\n  target_sources\(([^\n]+)\n([^\)]+)/Linux$1aarch64"\)\n  target_sources\($2\n$replace/' "$linux_aarch64_asms" "$src_root/CMakeLists.txt"
    perl -pi -e 'BEGIN { undef $/; $replace = shift } s/Windows([^\)]+)aarch64"\)\n  target_sources\(([^\n]+)\n([^\)]+)/Windows$1aarch64"\)\n  target_sources\($2\n$replace/' "$win_aarch64_asms" "$src_root/CMakeLists.txt"
    log "Updated $src_root/CMakeLists.txt"
}

echo "$config" | jq -c '.targets[]' | while read -r target; do
    name="$(echo "$target" | jq -r .name)"
    type="$(echo "$target" | jq -r .type)"
    exceptions=("$(echo "$target" | jq -r .exceptions | jq -r @sh)")
    log "Updating cmake list for ${name}"

    case "$type" in
        source)
            update_cmakelists_source "$name" "${exceptions[@]}"
            ;;
        assembly)
            update_cmakelists_assembly "$name"
            ;;
        *)
            fatal "Unknown target type: $type"
            ;;
    esac
done

if [[ "${fail_on_changes}" == true ]]; then
    if [ -n "$(git status --untracked-files=no --porcelain)" ]; then
        fatal "Changes in the cmake files detected. Please update. -- $(git diff)"
    else
        log "✅ CMake files are up-to-date."
    fi
fi
