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
linux_env_vars="$MATRIX_LINUX_ENV_VARS"
linux_env_var_pair_separator="${MATRIX_LINUX_ENV_VAR_PAIR_SEPARATOR:="="}"
linux_env_var_list_separator="${MATRIX_LINUX_ENV_VAR_LIST_SEPARATOR:=","}"
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
windows_env_vars="$MATRIX_WINDOWS_ENV_VARS"
windows_env_var_pair_separator="${MATRIX_WINDOWS_ENV_VAR_PAIR_SEPARATOR:="="}"
windows_env_var_list_separator="${MATRIX_WINDOWS_ENV_VAR_LIST_SEPARATOR:=","}"
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

# Specifying custom environment variables example:
#   MATRIX_WINDOWS_ENV_VARS="BUILD:Release;ARCH:x64" MATRIX_WINDOWS_ENV_VAR_PAIR_SEPARATOR=":" MATRIX_WINDOWS_ENV_VAR_LIST_SEPARATOR=";" ./generate_matrix.sh


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

# Function to parse environment variables and convert to JSON object
parse_env_vars() {
  local env_vars="$1"
  local pair_separator="$2"
  local list_separator="$3"

  if [[ -z "$env_vars" ]]; then
    echo "{}"
    return
  fi

  local json_obj="{}"

  # Split the env_vars string by list_separator
  IFS="$list_separator" read -ra env_pairs <<< "$env_vars"

  for pair in "${env_pairs[@]}"; do
    # Split each pair by pair_separator
    IFS="$pair_separator" read -ra kv <<< "$pair"
    if [[ ${#kv[@]} -eq 2 ]]; then
      local key="${kv[0]}"
      local value="${kv[1]}"
      # Add to JSON object using jq
      json_obj=$(echo "$json_obj" | jq -c --arg key "$key" --arg value "$value" '. + {($key): $value}')
    fi
  done

  echo "$json_obj"
}

# Parse environment variables for Linux and Windows
linux_env_vars_json=$(parse_env_vars "$linux_env_vars" "$linux_env_var_pair_separator" "$linux_env_var_list_separator")
windows_env_vars_json=$(parse_env_vars "$windows_env_vars" "$windows_env_var_pair_separator" "$windows_env_var_list_separator")

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


if [[ "$linux_5_9_enabled" == "true" ]]; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$linux_setup_command"  \
    --arg command "$linux_command"  \
    --arg command_arguments "$linux_5_9_command_arguments" \
    --arg container_image "$linux_5_9_container_image" \
    --arg runner "$linux_runner" \
    --argjson env_vars "$linux_env_vars_json" \
    '.config[.config| length] |= . + { "name": "5.9", "image": $container_image, "swift_version": "5.9", "platform": "Linux", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner, "env": $env_vars}')
fi

if [[ "$linux_5_10_enabled" == "true" ]]; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$linux_setup_command"  \
    --arg command "$linux_command"  \
    --arg command_arguments "$linux_5_10_command_arguments" \
    --arg container_image "$linux_5_10_container_image" \
    --arg runner "$linux_runner" \
    --argjson env_vars "$linux_env_vars_json" \
    '.config[.config| length] |= . + { "name": "5.10", "image": $container_image, "swift_version": "5.10", "platform": "Linux", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner, "env": $env_vars}')
fi

if [[ "$linux_6_0_enabled" == "true" ]]; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$linux_setup_command"  \
    --arg command "$linux_command"  \
    --arg command_arguments "$linux_6_0_command_arguments" \
    --arg container_image "$linux_6_0_container_image" \
    --arg runner "$linux_runner" \
    --argjson env_vars "$linux_env_vars_json" \
    '.config[.config| length] |= . + { "name": "6.0", "image": $container_image, "swift_version": "6.0", "platform": "Linux", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner, "env": $env_vars}')
fi

if [[ "$linux_6_1_enabled" == "true" ]]; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$linux_setup_command"  \
    --arg command "$linux_command"  \
    --arg command_arguments "$linux_6_1_command_arguments" \
    --arg container_image "$linux_6_1_container_image" \
    --arg runner "$linux_runner" \
    --argjson env_vars "$linux_env_vars_json" \
    '.config[.config| length] |= . + { "name": "6.1", "image": $container_image, "swift_version": "6.1", "platform": "Linux", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner, "env": $env_vars}')
fi

if [[ "$linux_6_2_enabled" == "true" ]]; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$linux_setup_command"  \
    --arg command "$linux_command"  \
    --arg command_arguments "$linux_6_2_command_arguments" \
    --arg container_image "$linux_6_2_container_image" \
    --arg runner "$linux_runner" \
    '.config[.config| length] |= . + { "name": "6.2", "image": $container_image, "swift_version": "6.2", "platform": "Linux", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner}')
fi

if [[ "$linux_nightly_next_enabled" == "true" ]]; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$linux_setup_command"  \
    --arg command "$linux_command"  \
    --arg command_arguments "$linux_nightly_next_command_arguments" \
    --arg container_image "$linux_nightly_next_container_image" \
    --arg runner "$linux_runner" \
    --argjson env_vars "$linux_env_vars_json" \
    '.config[.config| length] |= . + { "name": "nightly-next", "image": $container_image, "swift_version": "nightly-next", "platform": "Linux", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner, "env": $env_vars}')
fi

if [[ "$linux_nightly_main_enabled" == "true" ]]; then
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

if [[ "$windows_6_0_enabled" == "true" ]]; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$windows_setup_command"  \
    --arg command "$windows_command"  \
    --arg command_arguments "$windows_6_0_command_arguments" \
    --arg container_image "$windows_6_0_container_image" \
    --arg runner "$windows_6_0_runner" \
    --argjson env_vars "$windows_env_vars_json" \
    '.config[.config| length] |= . + { "name": "6.0", "image": $container_image, "swift_version": "6.0", "platform": "Windows", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner, "env": $env_vars }')
fi

if [[ "$windows_6_1_enabled" == "true" ]]; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$windows_setup_command"  \
    --arg command "$windows_command"  \
    --arg command_arguments "$windows_6_1_command_arguments" \
    --arg container_image "$windows_6_1_container_image" \
    --arg runner "$windows_6_1_runner" \
    --argjson env_vars "$windows_env_vars_json" \
    '.config[.config| length] |= . + { "name": "6.1", "image": $container_image, "swift_version": "6.1", "platform": "Windows", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner, "env": $env_vars }')
fi

if [[ "$windows_6_2_enabled" == "true" ]]; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$windows_setup_command"  \
    --arg command "$windows_command"  \
    --arg command_arguments "$windows_6_2_command_arguments" \
    --arg container_image "$windows_6_2_container_image" \
    --arg runner "$windows_6_2_runner" \
    '.config[.config| length] |= . + { "name": "6.2", "image": $container_image, "swift_version": "6.2", "platform": "Windows", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner }')
fi

if [[ "$windows_nightly_next_enabled" == "true" ]]; then
  matrix=$(echo "$matrix" | jq -c \
    --arg setup_command "$windows_setup_command"  \
    --arg command "$windows_command"  \
    --arg command_arguments "$windows_nightly_next_command_arguments" \
    --arg container_image "$windows_nightly_next_container_image" \
    --arg runner "$windows_nightly_next_runner" \
    --argjson env_vars "$windows_env_vars_json" \
    '.config[.config| length] |= . + { "name": "nightly-next", "image": $container_image, "swift_version": "nightly-next", "platform": "Windows", "command": $command, "command_arguments": $command_arguments, "setup_command": $setup_command, "runner": $runner, "env": $env_vars }')
fi

if [[ "$windows_nightly_main_enabled" == "true" ]]; then
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
