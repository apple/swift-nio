#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2017-2022 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

set -eu
here="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
root="$(realpath ${here}/..)"

printf "=> Checking linux tests... "
FIRST_OUT="$(git status --porcelain)"
ruby "$here/../scripts/generate_linux_tests.rb" > /dev/null
SECOND_OUT="$(git status --porcelain)"
if [[ "$FIRST_OUT" != "$SECOND_OUT" ]]; then
  printf "\033[0;31mmissing changes!\033[0m\n"
  git --no-pager diff
  exit 1
else
  printf "\033[0;32mokay.\033[0m\n"
fi

soundness_files=$(find ${root} -name ".*" -prune -o -print)

printf "=> Checking for unacceptable language... "
swift package check-nio-soundness check-language \
  --exclude-file ${root}/CODE_OF_CONDUCT.md \
  ${soundness_files}

printf "=> Checking license headers... "
swift package check-nio-soundness check-license-header \
  --exclude-extension txt \
  --exclude-extension md \
  --exclude-extension resolved \
  --exclude-extension modulemap \
  --exclude-file ${root}/Sources/CNIOAtomics/src/cpp_magic.h \
  --exclude-file ${root}/Sources/CNIOHTTPParser/AUTHORS \
  --exclude-file ${root}/Sources/CNIOHTTPParser/LICENSE-MIT \
  --exclude-file ${root}/Sources/CNIOHTTPParser/c_nio_http_parser.c \
  --exclude-file ${root}/Sources/CNIOHTTPParser/include/c_nio_http_parser.h \
  --exclude-file ${root}/Sources/CNIOSHA1/c_nio_sha1.c \
  --exclude-file ${root}/Sources/CNIOSHA1/include/CNIOSHA1.h \
  --exclude-file ${root}/dev/git.commit.template \
  --exclude-file ${root}/scripts/generate_linux_tests.rb \
  --exclude-directory ${root}/docker \
  ${soundness_files}
