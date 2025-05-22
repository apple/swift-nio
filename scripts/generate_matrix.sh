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

# Parameters
linux_command="$MATRIX_LINUX_COMMAND"  # required if any Linux pipeline is enabled
linux_setup_command="$MATRIX_LINUX_SETUP_COMMAND"
linux_5_9_enabled="${MATRIX_LINUX_5_9_ENABLED:=false}"
linux_5_9_command_arguments="$MATRIX_LINUX_5_9_COMMAND_ARGUMENTS"
linux_5_10_enabled="${MATRIX_LINUX_5_10_ENABLED:=true}"
linux_5_10_command_arguments="$MATRIX_LINUX_5_10_COMMAND_ARGUMENTS"
linux_6_0_enabled="${MATRIX_LINUX_6_0_ENABLED:=true}"
linux_6_1_enabled="${MATRIX_LINUX_6_1_ENABLED:=true}"
linux_6_0_command_arguments="$MATRIX_LINUX_6_0_COMMAND_ARGUMENTS"
linux_6_1_command_arguments="$MATRIX_LINUX_6_1_COMMAND_ARGUMENTS"
linux_nightly_next_enabled="${MATRIX_LINUX_NIGHTLY_NEXT_ENABLED:=${MATRIX_LINUX_NIGHTLY_6_1_ENABLED:=true}}"
linux_nightly_next_command_arguments="${MATRIX_LINUX_NIGHTLY_NEXT_COMMAND_ARGUMENTS:=${MATRIX_LINUX_NIGHTLY_6_1_COMMAND_ARGUMENTS}}"
linux_nightly_main_enabled="${MATRIX_LINUX_NIGHTLY_MAIN_ENABLED:=true}"
linux_nightly_main_command_arguments="$MATRIX_LINUX_NIGHTLY_MAIN_COMMAND_ARGUMENTS"

windows_command="$MATRIX_WINDOWS_COMMAND"  # required if any Windows pipeline is enabled
windows_setup_command="$MATRIX_WINDOWS_SETUP_COMMAND"
windows_6_0_enabled="${MATRIX_WINDOWS_6_0_ENABLED:=false}"
windows_6_1_enabled="${MATRIX_WINDOWS_6_1_ENABLED:=false}"
windows_6_0_command_arguments="$MATRIX_WINDOWS_6_0_COMMAND_ARGUMENTS"
windows_6_1_command_arguments="$MATRIX_WINDOWS_6_1_COMMAND_ARGUMENTS"
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
linux_nightly_next_container_image="swiftlang/swift:nightly-6.2-jammy"
linux_nightly_main_container_image="swiftlang/swift:nightly-main-jammy"

windows_6_0_runner="windows-2022"
windows_6_0_container_image="swift:6.0-windowsservercore-ltsc2022"
windows_6_1_runner="windows-2022"
windows_6_1_container_image="swift:6.1-windowsservercore-ltsc2022"
windows_nightly_next_runner="windows-2019"
windows_nightly_next_container_image="swiftlang/swift:nightly-6.2-windowsservercore-1809"
windows_nightly_main_runner="windows-2019"
windows_nightly_main_container_image="swiftlang/swift:nightly-main-windowsservercore-1809"

# Create matrix from inputs
matrix='{"config": []}'

## Linux
if [[ \
  "$linux_5_9_enabled" == "true" || \
  "$linux_5_10_enabled" == "true" || \
  "$linux_6_0_enabled" == "true" || \
  "$linux_6_1_enabled" == "true" || \
  "$linux_nightly_next_enabled" == "true" || \
  "$linux_nightly_main_enabled" == "true" \
]]; then
  if [[ -z "$linux_command" ]]; then
    echo "No linux command defined"; exit 1
  fi
fi


if [[ "$linux_5_9_enabled" == "true" ]]; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$linux_setup_command"  \
    --arg command "$linux_command"  \
    --arg command_arguments "$linux_5_9_command_arguments" \
    --arg container_image "$linux_5_9_container_image" \
    --arg runner "$linux_runner" \
    '.config[.config| length] |= . + { "name": "5.9", "image": $container_image, "swift_version": "5.9", "platform": "Linux", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner}')
fi

if [[ "$linux_5_10_enabled" == "true" ]]; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$linux_setup_command"  \
    --arg command "$linux_command"  \
    --arg command_arguments "$linux_5_10_command_arguments" \
    --arg container_image "$linux_5_10_container_image" \
    --arg runner "$linux_runner" \
    '.config[.config| length] |= . + { "name": "5.10", "image": $container_image, "swift_version": "5.10", "platform": "Linux", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner}')
fi

if [[ "$linux_6_0_enabled" == "true" ]]; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$linux_setup_command"  \
    --arg command "$linux_command"  \
    --arg command_arguments "$linux_6_0_command_arguments" \
    --arg container_image "$linux_6_0_container_image" \
    --arg runner "$linux_runner" \
    '.config[.config| length] |= . + { "name": "6.0", "image": $container_image, "swift_version": "6.0", "platform": "Linux", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner}')
fi

if [[ "$linux_6_1_enabled" == "true" ]]; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$linux_setup_command"  \
    --arg command "$linux_command"  \
    --arg command_arguments "$linux_6_1_command_arguments" \
    --arg container_image "$linux_6_1_container_image" \
    --arg runner "$linux_runner" \
    '.config[.config| length] |= . + { "name": "6.1", "image": $container_image, "swift_version": "6.1", "platform": "Linux", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner}')
fi

if [[ "$linux_nightly_next_enabled" == "true" ]]; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$linux_setup_command"  \
    --arg command "$linux_command"  \
    --arg command_arguments "$linux_nightly_next_command_arguments" \
    --arg container_image "$linux_nightly_next_container_image" \
    --arg runner "$linux_runner" \
    '.config[.config| length] |= . + { "name": "nightly-next", "image": $container_image, "swift_version": "nightly-next", "platform": "Linux", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner}')
fi

if [[ "$linux_nightly_main_enabled" == "true" ]]; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$linux_setup_command"  \
    --arg command "$linux_command"  \
    --arg command_arguments "$linux_nightly_main_command_arguments" \
    --arg container_image "$linux_nightly_main_container_image" \
    --arg runner "$linux_runner" \
    '.config[.config| length] |= . + { "name": "nightly-main", "image": $container_image, "swift_version": "nightly-main", "platform": "Linux", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner}')
fi

## Windows
if [[ \
  "$windows_6_0_enabled" == "true" || \
  "$windows_nightly_next_enabled" == "true" || \
  "$windows_nightly_main_enabled" == "true" \
]]; then
  if [[ -z "$windows_command" ]]; then
    echo "No windows command defined"; exit 1
  fi
fi

if [[ "$windows_6_0_enabled" == "true" ]]; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$windows_setup_command"  \
    --arg command "$windows_command"  \
    --arg command_arguments "$windows_6_0_command_arguments" \
    --arg container_image "$windows_6_0_container_image" \
    --arg runner "$windows_6_0_runner" \
    '.config[.config| length] |= . + { "name": "6.0", "image": $container_image, "swift_version": "6.0", "platform": "Windows", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner }')
fi

if [[ "$windows_6_1_enabled" == "true" ]]; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$windows_setup_command"  \
    --arg command "$windows_command"  \
    --arg command_arguments "$windows_6_1_command_arguments" \
    --arg container_image "$windows_6_1_container_image" \
    --arg runner "$windows_6_1_runner" \
    '.config[.config| length] |= . + { "name": "6.1", "image": $container_image, "swift_version": "6.1", "platform": "Windows", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner }')
fi

if [[ "$windows_nightly_next_enabled" == "true" ]]; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$windows_setup_command"  \
    --arg command "$windows_command"  \
    --arg command_arguments "$windows_nightly_next_command_arguments" \
    --arg container_image "$windows_nightly_next_container_image" \
    --arg runner "$windows_nightly_next_runner" \
    '.config[.config| length] |= . + { "name": "nightly-next", "image": $container_image, "swift_version": "nightly-next", "platform": "Windows", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner }')
fi

if [[ "$windows_nightly_main_enabled" == "true" ]]; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$windows_setup_command"  \
    --arg command "$windows_command"  \
    --arg command_arguments "$windows_nightly_main_command_arguments" \
    --arg container_image "$windows_nightly_main_container_image" \
    --arg runner "$windows_nightly_main_runner" \
    '.config[.config| length] |= . + { "name": "nightly-main", "image": $container_image, "swift_version": "nightly-main", "platform": "Windows", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner }')
fi

echo "$matrix" | jq -c