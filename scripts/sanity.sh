#!/bin/bash

set -eu

printf "=> Checking linux tests... "
FIRST_OUT="$(git status --porcelain)"
ruby scripts/generate_linux_tests.rb > /dev/null
SECOND_OUT="$(git status --porcelain)"
if [[ "$FIRST_OUT" != "$SECOND_OUT" ]]; then
  printf "\033[0;31mmissing changes!\033[0m\n"
  git --no-pager diff
  exit 1
else
  printf "\033[0;32mokay.\033[0m\n"
fi

printf "=> Checking license headers... "
NON_LICENSED_FILES="$(grep --include=\*.swift --exclude-dir=.build -rL "Licensed under Apache License v2.0" .)"
if [[ -n "$NON_LICENSED_FILES" ]]; then
  printf "\033[0;31mmissing headers!\033[0m\n"
  printf "$NON_LICENSED_FILES\n"
  exit 1
else
  printf "\033[0;32mokay.\033[0m\n"
fi
