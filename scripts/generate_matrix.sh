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
set -x

# Extract swift-tools-version from a manifest file
get_tools_version() {
    local manifest="$1"
    if [[ ! -f "$manifest" ]]; then
        echo ""
        return
    fi

    # Parse the first line: // swift-tools-version:X.Y or // swift-tools-version: X.Y
    local tools_version
    tools_version=$(head -n 1 "$manifest" | sed -n 's#^// *swift-tools-version: *\([0-9.]*\).*#\1#p')
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

# Find minimum Swift version across all manifests
if [[ -z "${MATRIX_MIN_SWIFT_VERSION:-}" ]]; then
    min_version=""

    # Check default Package.swift
    default_version=$(get_tools_version "Package.swift")
    if [[ -n "$default_version" ]]; then
        min_version="$default_version"
        echo "Found Package.swift with tools-version: $default_version" >&2
    fi

    # Check all version-specific manifests
    for manifest in Package@swift-*.swift; do
        if [[ ! -f "$manifest" ]]; then
            continue
        fi

        version=$(get_tools_version "$manifest")
        if [[ -z "$version" ]]; then
            continue
        fi

        echo "Found $manifest with tools-version: $version" >&2

        # If this version is less than current minimum, update minimum
        if [[ -z "$min_version" ]] || ! version_gte "$version" "$min_version"; then
            min_version="$version"
        fi
    done

    if [[ -n "$min_version" ]]; then
        MATRIX_MIN_SWIFT_VERSION="$min_version"
        echo "Minimum Swift tools version: $MATRIX_MIN_SWIFT_VERSION" >&2
    else
        echo "Warning: Could not find any Swift tools version in Package manifests" >&2
    fi
fi

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
        echo "Skipping Swift $version (< minimum $MATRIX_MIN_SWIFT_VERSION)" >&2
        return 1
    fi
}

# Parameters
linux_command="$MATRIX_LINUX_COMMAND"  # required if any Linux pipeline is enabled
linux_setup_command="$MATRIX_LINUX_SETUP_COMMAND"
linux_5_9_enabled="${MATRIX_LINUX_5_9_ENABLED:=false}"
linux_5_9_command_arguments="$MATRIX_LINUX_5_9_COMMAND_ARGUMENTS"
linux_5_10_enabled="${MATRIX_LINUX_5_10_ENABLED:=true}"
linux_5_10_command_arguments="$MATRIX_LINUX_5_10_COMMAND_ARGUMENTS"
linux_6_0_enabled="${MATRIX_LINUX_6_0_ENABLED:=true}"
linux_6_1_enabled="${MATRIX_LINUX_6_1_ENABLED:=true}"
linux_6_2_enabled="${MATRIX_LINUX_6_2_ENABLED:=true}"
linux_6_0_command_arguments="$MATRIX_LINUX_6_0_COMMAND_ARGUMENTS"
linux_6_1_command_arguments="$MATRIX_LINUX_6_1_COMMAND_ARGUMENTS"
linux_6_2_command_arguments="$MATRIX_LINUX_6_2_COMMAND_ARGUMENTS"
linux_nightly_next_enabled="${MATRIX_LINUX_NIGHTLY_NEXT_ENABLED:=${MATRIX_LINUX_NIGHTLY_6_1_ENABLED:=true}}"
linux_nightly_next_command_arguments="${MATRIX_LINUX_NIGHTLY_NEXT_COMMAND_ARGUMENTS:=${MATRIX_LINUX_NIGHTLY_6_1_COMMAND_ARGUMENTS}}"
linux_nightly_main_enabled="${MATRIX_LINUX_NIGHTLY_MAIN_ENABLED:=true}"
linux_nightly_main_command_arguments="$MATRIX_LINUX_NIGHTLY_MAIN_COMMAND_ARGUMENTS"

windows_command="$MATRIX_WINDOWS_COMMAND"  # required if any Windows pipeline is enabled
windows_setup_command="$MATRIX_WINDOWS_SETUP_COMMAND"
windows_6_0_enabled="${MATRIX_WINDOWS_6_0_ENABLED:=false}"
windows_6_1_enabled="${MATRIX_WINDOWS_6_1_ENABLED:=false}"
windows_6_2_enabled="${MATRIX_WINDOWS_6_2_ENABLED:=false}"
windows_6_0_command_arguments="$MATRIX_WINDOWS_6_0_COMMAND_ARGUMENTS"
windows_6_1_command_arguments="$MATRIX_WINDOWS_6_1_COMMAND_ARGUMENTS"
windows_6_2_command_arguments="$MATRIX_WINDOWS_6_1_COMMAND_ARGUMENTS"
windows_nightly_next_enabled="${MATRIX_WINDOWS_NIGHTLY_NEXT_ENABLED:=${MATRIX_WINDOWS_NIGHTLY_6_1_ENABLED:=false}}"
windows_nightly_next_command_arguments="${MATRIX_WINDOWS_NIGHTLY_NEXT_COMMAND_ARGUMENTS:=${MATRIX_WINDOWS_NIGHTLY_6_1_COMMAND_ARGUMENTS}}"
windows_nightly_main_enabled="${MATRIX_WINDOWS_NIGHTLY_MAIN_ENABLED:=false}"
windows_nightly_main_command_arguments="$MATRIX_WINDOWS_NIGHTLY_MAIN_COMMAND_ARGUMENTS"

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

# Get pre-parsed environment variables JSON
linux_env_vars_json="${MATRIX_LINUX_ENV_VARS_JSON:-"{}"}"
windows_env_vars_json="${MATRIX_WINDOWS_ENV_VARS_JSON:-"{}"}"

# Create matrix from inputs
matrix='{"config": []}'

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
    echo "No linux command defined"; exit 1
  fi
fi


if [[ "$linux_5_9_enabled" == "true" ]] && should_include_version "5.9"; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$linux_setup_command"  \
    --arg command "$linux_command"  \
    --arg command_arguments "$linux_5_9_command_arguments" \
    --arg container_image "$linux_5_9_container_image" \
    --arg runner "$linux_runner" \
    --argjson env_vars "$linux_env_vars_json" \
    '.config[.config| length] |= . + { "name": "5.9", "image": $container_image, "swift_version": "5.9", "platform": "Linux", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner, "env": $env_vars}')
fi

if [[ "$linux_5_10_enabled" == "true" ]] && should_include_version "5.10"; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$linux_setup_command"  \
    --arg command "$linux_command"  \
    --arg command_arguments "$linux_5_10_command_arguments" \
    --arg container_image "$linux_5_10_container_image" \
    --arg runner "$linux_runner" \
    --argjson env_vars "$linux_env_vars_json" \
    '.config[.config| length] |= . + { "name": "5.10", "image": $container_image, "swift_version": "5.10", "platform": "Linux", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner, "env": $env_vars}')
fi

if [[ "$linux_6_0_enabled" == "true" ]] && should_include_version "6.0"; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$linux_setup_command"  \
    --arg command "$linux_command"  \
    --arg command_arguments "$linux_6_0_command_arguments" \
    --arg container_image "$linux_6_0_container_image" \
    --arg runner "$linux_runner" \
    --argjson env_vars "$linux_env_vars_json" \
    '.config[.config| length] |= . + { "name": "6.0", "image": $container_image, "swift_version": "6.0", "platform": "Linux", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner, "env": $env_vars}')
fi

if [[ "$linux_6_1_enabled" == "true" ]] && should_include_version "6.1"; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$linux_setup_command"  \
    --arg command "$linux_command"  \
    --arg command_arguments "$linux_6_1_command_arguments" \
    --arg container_image "$linux_6_1_container_image" \
    --arg runner "$linux_runner" \
    --argjson env_vars "$linux_env_vars_json" \
    '.config[.config| length] |= . + { "name": "6.1", "image": $container_image, "swift_version": "6.1", "platform": "Linux", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner, "env": $env_vars}')
fi

if [[ "$linux_6_2_enabled" == "true" ]] && should_include_version "6.2"; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$linux_setup_command"  \
    --arg command "$linux_command"  \
    --arg command_arguments "$linux_6_2_command_arguments" \
    --arg container_image "$linux_6_2_container_image" \
    --arg runner "$linux_runner" \
    --argjson env_vars "$linux_env_vars_json" \
    '.config[.config| length] |= . + { "name": "6.2", "image": $container_image, "swift_version": "6.2", "platform": "Linux", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner, "env": $env_vars}')
fi

if [[ "$linux_nightly_next_enabled" == "true" ]] && should_include_version "nightly-next"; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$linux_setup_command"  \
    --arg command "$linux_command"  \
    --arg command_arguments "$linux_nightly_next_command_arguments" \
    --arg container_image "$linux_nightly_next_container_image" \
    --arg runner "$linux_runner" \
    --argjson env_vars "$linux_env_vars_json" \
    '.config[.config| length] |= . + { "name": "nightly-next", "image": $container_image, "swift_version": "nightly-next", "platform": "Linux", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner, "env": $env_vars}')
fi

if [[ "$linux_nightly_main_enabled" == "true" ]] && should_include_version "nightly-main"; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$linux_setup_command"  \
    --arg command "$linux_command"  \
    --arg command_arguments "$linux_nightly_main_command_arguments" \
    --arg container_image "$linux_nightly_main_container_image" \
    --arg runner "$linux_runner" \
    --argjson env_vars "$linux_env_vars_json" \
    '.config[.config| length] |= . + { "name": "nightly-main", "image": $container_image, "swift_version": "nightly-main", "platform": "Linux", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner, "env": $env_vars}')
fi

## Windows
if [[ \
  "$windows_6_0_enabled" == "true" || \
  "$windows_6_1_enabled" == "true" || \
  "$windows_nightly_next_enabled" == "true" || \
  "$windows_nightly_main_enabled" == "true" \
]]; then
  if [[ -z "$windows_command" ]]; then
    echo "No windows command defined"; exit 1
  fi
fi

if [[ "$windows_6_0_enabled" == "true" ]] && should_include_version "6.0"; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$windows_setup_command"  \
    --arg command "$windows_command"  \
    --arg command_arguments "$windows_6_0_command_arguments" \
    --arg container_image "$windows_6_0_container_image" \
    --arg runner "$windows_6_0_runner" \
    --argjson env_vars "$windows_env_vars_json" \
    '.config[.config| length] |= . + { "name": "6.0", "image": $container_image, "swift_version": "6.0", "platform": "Windows", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner, "env": $env_vars }')
fi

if [[ "$windows_6_1_enabled" == "true" ]] && should_include_version "6.1"; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$windows_setup_command"  \
    --arg command "$windows_command"  \
    --arg command_arguments "$windows_6_1_command_arguments" \
    --arg container_image "$windows_6_1_container_image" \
    --arg runner "$windows_6_1_runner" \
    --argjson env_vars "$windows_env_vars_json" \
    '.config[.config| length] |= . + { "name": "6.1", "image": $container_image, "swift_version": "6.1", "platform": "Windows", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner, "env": $env_vars }')
fi

if [[ "$windows_6_2_enabled" == "true" ]] && should_include_version "6.2"; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$windows_setup_command"  \
    --arg command "$windows_command"  \
    --arg command_arguments "$windows_6_2_command_arguments" \
    --arg container_image "$windows_6_2_container_image" \
    --arg runner "$windows_6_2_runner" \
    --argjson env_vars "$windows_env_vars_json" \
    '.config[.config| length] |= . + { "name": "6.2", "image": $container_image, "swift_version": "6.2", "platform": "Windows", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner, "env": $env_vars }')
fi

if [[ "$windows_nightly_next_enabled" == "true" ]] && should_include_version "nightly-next"; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$windows_setup_command"  \
    --arg command "$windows_command"  \
    --arg command_arguments "$windows_nightly_next_command_arguments" \
    --arg container_image "$windows_nightly_next_container_image" \
    --arg runner "$windows_nightly_next_runner" \
    --argjson env_vars "$windows_env_vars_json" \
    '.config[.config| length] |= . + { "name": "nightly-next", "image": $container_image, "swift_version": "nightly-next", "platform": "Windows", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner, "env": $env_vars }')
fi

if [[ "$windows_nightly_main_enabled" == "true" ]] && should_include_version "nightly-main"; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$windows_setup_command"  \
    --arg command "$windows_command"  \
    --arg command_arguments "$windows_nightly_main_command_arguments" \
    --arg container_image "$windows_nightly_main_container_image" \
    --arg runner "$windows_nightly_main_runner" \
    --argjson env_vars "$windows_env_vars_json" \
    '.config[.config| length] |= . + { "name": "nightly-main", "image": $container_image, "swift_version": "nightly-main", "platform": "Windows", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner, "env": $env_vars }')
fi

echo "$matrix" | jq -c
