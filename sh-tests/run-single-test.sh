#!/bin/bash

(
# this sub-shell is where the actual test is run
set -eu
set -x
set -o pipefail

test="$1"
tmp="$2"
root="$3"
here="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

source "$here/test_functions.sh"
source "$test"
wait
)
exit_code=$?
exit $exit_code
