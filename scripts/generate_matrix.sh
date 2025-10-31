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

set -uo pipefail

log() { printf -- "** %s\n" "$*" >&2; }
error() { printf -- "** ERROR: %s\n" "$*" >&2; }
fatal() { error "$@"; exit 1; }

# Binary dependencies
JQ_BIN="${JQ_BIN:-$(which jq 2> /dev/null)}"; test -n "$JQ_BIN" || fatal "JQ_BIN unset and no jq on PATH"
SED_BIN="${SED_BIN:-$(which sed 2> /dev/null)}"; test -n "$SED_BIN" || fatal "SED_BIN unset and no sed on PATH"
HEAD_BIN="${HEAD_BIN:-$(which head 2> /dev/null)}"; test -n "$HEAD_BIN" || fatal "HEAD_BIN unset and no head on PATH"


# Parameters
find_subdirectory_manifests_enabled="${FIND_SUBDIRECTORY_MANIFESTS_ENABLED:=false}"

linux_command="${MATRIX_LINUX_COMMAND:-}"  # required if any Linux pipeline is enabled
linux_setup_command="${MATRIX_LINUX_SETUP_COMMAND:-}"
linux_5_9_enabled="${MATRIX_LINUX_5_9_ENABLED:=false}"
linux_5_9_command_arguments="${MATRIX_LINUX_5_9_COMMAND_ARGUMENTS:-}"
linux_5_10_enabled="${MATRIX_LINUX_5_10_ENABLED:=true}"
linux_5_10_command_arguments="${MATRIX_LINUX_5_10_COMMAND_ARGUMENTS:-}"
linux_6_0_enabled="${MATRIX_LINUX_6_0_ENABLED:=true}"
linux_6_1_enabled="${MATRIX_LINUX_6_1_ENABLED:=true}"
linux_6_2_enabled="${MATRIX_LINUX_6_2_ENABLED:=true}"
linux_6_0_command_arguments="${MATRIX_LINUX_6_0_COMMAND_ARGUMENTS:-}"
linux_6_1_command_arguments="${MATRIX_LINUX_6_1_COMMAND_ARGUMENTS:-}"
linux_6_2_command_arguments="${MATRIX_LINUX_6_2_COMMAND_ARGUMENTS:-}"
linux_nightly_next_enabled="${MATRIX_LINUX_NIGHTLY_NEXT_ENABLED:=${MATRIX_LINUX_NIGHTLY_6_1_ENABLED:=true}}"
linux_nightly_next_command_arguments="${MATRIX_LINUX_NIGHTLY_NEXT_COMMAND_ARGUMENTS:=${MATRIX_LINUX_NIGHTLY_6_1_COMMAND_ARGUMENTS:-}}"
linux_nightly_main_enabled="${MATRIX_LINUX_NIGHTLY_MAIN_ENABLED:=true}"
linux_nightly_main_command_arguments="${MATRIX_LINUX_NIGHTLY_MAIN_COMMAND_ARGUMENTS:-}"

windows_command="${MATRIX_WINDOWS_COMMAND:-}"  # required if any Windows pipeline is enabled
windows_setup_command="${MATRIX_WINDOWS_SETUP_COMMAND:-}"
windows_6_0_enabled="${MATRIX_WINDOWS_6_0_ENABLED:=false}"
windows_6_1_enabled="${MATRIX_WINDOWS_6_1_ENABLED:=false}"
windows_6_2_enabled="${MATRIX_WINDOWS_6_2_ENABLED:=false}"
windows_6_0_command_arguments="${MATRIX_WINDOWS_6_0_COMMAND_ARGUMENTS:-}"
windows_6_1_command_arguments="${MATRIX_WINDOWS_6_1_COMMAND_ARGUMENTS:-}"
windows_6_2_command_arguments="${MATRIX_WINDOWS_6_2_COMMAND_ARGUMENTS:-}"
windows_nightly_next_enabled="${MATRIX_WINDOWS_NIGHTLY_NEXT_ENABLED:=${MATRIX_WINDOWS_NIGHTLY_6_1_ENABLED:=false}}"
windows_nightly_next_command_arguments="${MATRIX_WINDOWS_NIGHTLY_NEXT_COMMAND_ARGUMENTS:=${MATRIX_WINDOWS_NIGHTLY_6_1_COMMAND_ARGUMENTS:-}}"
windows_nightly_main_enabled="${MATRIX_WINDOWS_NIGHTLY_MAIN_ENABLED:=false}"
windows_nightly_main_command_arguments="${MATRIX_WINDOWS_NIGHTLY_MAIN_COMMAND_ARGUMENTS:-}"

# Get pre-parsed environment variables JSON
linux_env_vars_json="${MATRIX_LINUX_ENV_VARS_JSON:-"{}"}"
windows_env_vars_json="${MATRIX_WINDOWS_ENV_VARS_JSON:-"{}"}"

# Defaults
linux_runner="ubuntu-latest"
linux_5_9_container_image="swift:5.9-jammy"
linux_5_10_container_image="swift:5.10-jammy"
linux_6_0_container_image="swift:6.0-jammy"
linux_6_1_container_image="swift:6.1-jammy"
linux_6_2_container_image="swift:6.2-noble"
linux_nightly_next_container_image="swiftlang/swift:nightly-6.2-jammy"
linux_nightly_main_container_image="swiftlang/swift:nightly-main-jammy"

windows_6_0_runner="windows-2022"
windows_6_0_container_image="swift:6.0-windowsservercore-ltsc2022"
windows_6_1_runner="windows-2022"
windows_6_1_container_image="swift:6.1-windowsservercore-ltsc2022"
windows_6_2_runner="windows-2022"
windows_6_2_container_image="swift:6.2-windowsservercore-ltsc2022"
windows_nightly_next_runner="windows-2022"
windows_nightly_next_container_image="swiftlang/swift:nightly-6.2-windowsservercore-ltsc2022"
windows_nightly_main_runner="windows-2022"
windows_nightly_main_container_image="swiftlang/swift:nightly-main-windowsservercore-ltsc2022"

# Extract swift-tools-version from a manifest file
get_tools_version() {
    local manifest="$1"
    if [[ ! -f "$manifest" ]]; then
        echo ""
        return
    fi

    # Parse the first line: // swift-tools-version:X.Y or // swift-tools-version: X.Y
    local tools_version
    tools_version=$("$HEAD_BIN" -n 1 "$manifest" | "$SED_BIN" -n 's#^// *swift-tools-version: *\([0-9.]*\).*#\1#p')
    echo "$tools_version"
}

# Compare versions using SemVer: returns 0 if v1 >= v2, 1 otherwise
version_gte() {
    local v1="$1"
    local v2="$2"

    # Parse v1 as major.minor.patch
    IFS='.' read -r v1_major v1_minor v1_patch <<< "$v1"
    v1_minor=${v1_minor:-0}
    v1_patch=${v1_patch:-0}

    # Parse v2 as major.minor.patch
    IFS='.' read -r v2_major v2_minor v2_patch <<< "$v2"
    v2_minor=${v2_minor:-0}
    v2_patch=${v2_patch:-0}

    # Compare major
    if [[ $v1_major -gt $v2_major ]]; then return 0; fi
    if [[ $v1_major -lt $v2_major ]]; then return 1; fi

    # Major equal, compare minor
    if [[ $v1_minor -gt $v2_minor ]]; then return 0; fi
    if [[ $v1_minor -lt $v2_minor ]]; then return 1; fi

    # Major and minor equal, compare patch
    if [[ $v1_patch -ge $v2_patch ]]; then return 0; fi
    return 1
}

# Find minimum Swift version across all Package manifests
# Checks Package.swift and all Package@swift-*.swift files in current directory and subdirectories
# Returns the minimum tools version found across all manifests
find_minimum_swift_version() {
    local min_version=""

    # Check default Package.swift in current directory
    local default_version
    default_version=$(get_tools_version "Package.swift")
    if [[ -n "$default_version" ]]; then
        min_version="$default_version"
        log "Found Package.swift with tools-version: $default_version"
    fi

    # Check all Package.swift files in subdirectories (multi-package repository support)
    if [[ "$find_subdirectory_manifests_enabled" == "true" ]]; then
        while read -r manifest; do
            if [[ -f "$manifest" ]]; then
                local version
                version=$(get_tools_version "$manifest")
                if [[ -n "$version" ]]; then
                    log "Found $manifest with tools-version: $version"

                    # If this version is less than current minimum, update minimum
                    if [[ -z "$min_version" ]] || version_gte "$min_version" "$version"; then
                        min_version="$version"
                    fi
                fi
            fi
        done < <(ls -1 ./*/Package.swift 2>/dev/null || true)
    fi

    # Check all version-specific manifests in current directory
    for manifest in Package@swift-*.swift; do
        if [[ ! -f "$manifest" ]]; then
            continue
        fi

        local version
        version=$(get_tools_version "$manifest")
        if [[ -z "$version" ]]; then
            continue
        fi

        log "Found $manifest with tools-version: $version"

        # If this version is less than current minimum, update minimum
        if [[ -z "$min_version" ]] || version_gte "$min_version" "$version"; then
            min_version="$version"
        fi
    done

    # Check all version-specific manifests in subdirectories
    if [[ "$find_subdirectory_manifests_enabled" == "true" ]]; then
        while read -r manifest; do
            if [[ -f "$manifest" ]]; then
                local version
                version=$(get_tools_version "$manifest")
                if [[ -n "$version" ]]; then
                    log "Found $manifest with tools-version: $version"

                    # If this version is less than current minimum, update minimum
                    if [[ -z "$min_version" ]] || version_gte "$min_version" "$version"; then
                        min_version="$version"
                    fi
                fi
            fi
        done < <(ls -1 ./*/Package@swift-*.swift 2>/dev/null || true)
    fi

    if [[ -n "$min_version" ]]; then
        echo "$min_version"
    else
        log "Warning: Could not find any Swift tools version in Package manifests"
        echo ""
    fi
}

# Check if a Swift version should be included in the matrix
# Nightlies are always included
# If MATRIX_MIN_SWIFT_VERSION is "none", all versions are included
# If MATRIX_MIN_SWIFT_VERSION is not set, it's auto-detected from Package manifests
# If MATRIX_MIN_SWIFT_VERSION is set to a version, that version is used as the minimum
should_include_version() {
    local version="$1"

    # If minimum version check is disabled, include everything
    if [[ "${MATRIX_MIN_SWIFT_VERSION:-}" == "none" ]]; then
        return 0
    fi

    # If no minimum version specified, include everything
    if [[ -z "${MATRIX_MIN_SWIFT_VERSION:-}" ]]; then
        return 0
    fi

    # Nightly builds always included
    if [[ "$version" =~ ^nightly- ]]; then
        return 0
    fi

    # Check if version >= minimum
    if version_gte "$version" "$MATRIX_MIN_SWIFT_VERSION"; then
        return 0
    else
        log "Skipping Swift $version (< minimum $MATRIX_MIN_SWIFT_VERSION)"
        return 1
    fi
}

# Add a matrix entry for a specific Swift version and platform
# Parameters:
#   $1: platform ("Linux" or "Windows")
#   $2: version name (e.g., "5.9", "6.0", "nightly-main")
#   $3: enabled flag ("true" or "false")
#   $4: setup_command
#   $5: command
#   $6: command_arguments
#   $7: container_image
#   $8: runner
#   $9: env_vars_json
add_matrix_entry() {
    local platform="$1"
    local version="$2"
    local enabled="$3"
    local setup_command="$4"
    local command="$5"
    local command_arguments="$6"
    local container_image="$7"
    local runner="$8"
    local env_vars_json="$9"

    if [[ "$enabled" == "true" ]] && should_include_version "$version"; then
        # shellcheck disable=SC2016  # Our use of JQ_BIN means that shellcheck can't tell this is a `jq` invocation
        matrix=$(echo "$matrix" | "$JQ_BIN" -c \
            --arg setup_command "$setup_command" \
            --arg command "$command" \
            --arg command_arguments "$command_arguments" \
            --arg container_image "$container_image" \
            --arg runner "$runner" \
            --arg platform "$platform" \
            --arg version "$version" \
            --argjson env_vars "$env_vars_json" \
            '.config[.config| length] |= . + { "name": $version, "image": $container_image, "swift_version": $version, "platform": $platform, "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner, "env": $env_vars}')
    fi
}

# Create matrix from inputs
matrix='{"config": []}'

# Auto-detect minimum Swift version if not explicitly set
if [[ -z "${MATRIX_MIN_SWIFT_VERSION:-}" ]]; then
    MATRIX_MIN_SWIFT_VERSION=$(find_minimum_swift_version)
    if [[ -n "$MATRIX_MIN_SWIFT_VERSION" ]]; then
        log "Minimum Swift tools version: $MATRIX_MIN_SWIFT_VERSION"
    fi
fi

## Linux
if [[ \
  "$linux_5_9_enabled" == "true" || \
  "$linux_5_10_enabled" == "true" || \
  "$linux_6_0_enabled" == "true" || \
  "$linux_6_1_enabled" == "true" || \
  "$linux_6_2_enabled" == "true" || \
  "$linux_nightly_next_enabled" == "true" || \
  "$linux_nightly_main_enabled" == "true" \
]]; then
  if [[ -z "$linux_command" ]]; then
    fatal "No linux command defined"
  fi
fi

#                 Platform   Version         Enabled                        Setup                   Command          Arguments                               Image                                 Runner           Env
add_matrix_entry "Linux"    "5.9"           "$linux_5_9_enabled"           "$linux_setup_command"  "$linux_command" "$linux_5_9_command_arguments"          "$linux_5_9_container_image"          "$linux_runner"  "$linux_env_vars_json"
add_matrix_entry "Linux"    "5.10"          "$linux_5_10_enabled"          "$linux_setup_command"  "$linux_command" "$linux_5_10_command_arguments"         "$linux_5_10_container_image"         "$linux_runner"  "$linux_env_vars_json"
add_matrix_entry "Linux"    "6.0"           "$linux_6_0_enabled"           "$linux_setup_command"  "$linux_command" "$linux_6_0_command_arguments"          "$linux_6_0_container_image"          "$linux_runner"  "$linux_env_vars_json"
add_matrix_entry "Linux"    "6.1"           "$linux_6_1_enabled"           "$linux_setup_command"  "$linux_command" "$linux_6_1_command_arguments"          "$linux_6_1_container_image"          "$linux_runner"  "$linux_env_vars_json"
add_matrix_entry "Linux"    "6.2"           "$linux_6_2_enabled"           "$linux_setup_command"  "$linux_command" "$linux_6_2_command_arguments"          "$linux_6_2_container_image"          "$linux_runner"  "$linux_env_vars_json"
add_matrix_entry "Linux"    "nightly-next"  "$linux_nightly_next_enabled"  "$linux_setup_command"  "$linux_command" "$linux_nightly_next_command_arguments" "$linux_nightly_next_container_image" "$linux_runner"  "$linux_env_vars_json"
add_matrix_entry "Linux"    "nightly-main"  "$linux_nightly_main_enabled"  "$linux_setup_command"  "$linux_command" "$linux_nightly_main_command_arguments" "$linux_nightly_main_container_image" "$linux_runner"  "$linux_env_vars_json"

## Windows
if [[ \
  "$windows_6_0_enabled" == "true" || \
  "$windows_6_1_enabled" == "true" || \
  "$windows_nightly_next_enabled" == "true" || \
  "$windows_nightly_main_enabled" == "true" \
]]; then
  if [[ -z "$windows_command" ]]; then
    fatal "No windows command defined"
  fi
fi

#                 Platform   Version         Enabled                          Setup                     Command            Arguments                                 Image                                   Runner                         Env
add_matrix_entry "Windows"  "6.0"           "$windows_6_0_enabled"           "$windows_setup_command"  "$windows_command" "$windows_6_0_command_arguments"          "$windows_6_0_container_image"          "$windows_6_0_runner"          "$windows_env_vars_json"
add_matrix_entry "Windows"  "6.1"           "$windows_6_1_enabled"           "$windows_setup_command"  "$windows_command" "$windows_6_1_command_arguments"          "$windows_6_1_container_image"          "$windows_6_1_runner"          "$windows_env_vars_json"
add_matrix_entry "Windows"  "6.2"           "$windows_6_2_enabled"           "$windows_setup_command"  "$windows_command" "$windows_6_2_command_arguments"          "$windows_6_2_container_image"          "$windows_6_2_runner"          "$windows_env_vars_json"
add_matrix_entry "Windows"  "nightly-next"  "$windows_nightly_next_enabled"  "$windows_setup_command"  "$windows_command" "$windows_nightly_next_command_arguments" "$windows_nightly_next_container_image" "$windows_nightly_next_runner" "$windows_env_vars_json"
add_matrix_entry "Windows"  "nightly-main"  "$windows_nightly_main_enabled"  "$windows_setup_command"  "$windows_command" "$windows_nightly_main_command_arguments" "$windows_nightly_main_container_image" "$windows_nightly_main_runner" "$windows_env_vars_json"


echo "$matrix" | "$JQ_BIN" -c
