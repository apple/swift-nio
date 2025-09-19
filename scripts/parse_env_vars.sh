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
env_vars="${ENV_VARS:=""}"
env_var_pair_separator="${ENV_VAR_PAIR_SEPARATOR:="="}"
env_var_list_separator="${ENV_VAR_LIST_SEPARATOR:=","}"

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

# Execute the function with the environment variables
parse_env_vars "$env_vars" "$env_var_pair_separator" "$env_var_list_separator"
