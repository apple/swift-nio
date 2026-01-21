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

set -eu
here="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

function usage() {
    echo >&2 "$0 SWIFT_BINARY_BASE SWIFT_BINARY_COMPETITOR"
    echo >&2
    echo >&2 "Runs the NIOPerformanceTester tool with 'swift' binary "
    echo >&2 "SWIFT_BINARY_BASE against SWIFT_BINARY_COMPETITOR."
    echo >&2
    echo >&2 "Example:"
    echo >&2 "$0 /Library/Developer/Toolchains/swift-4.1-RELEASE.xctoolchain/usr/bin/swift /Library/Developer/Toolchains/swift-4.2-DEVELOPMENT-SNAPSHOT-2018-08-07-a.xctoolchain/usr/bin/swift"
}

function write_compare_r_script() {
    cat >> "$1" <<"EOF"
#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly=TRUE)
perfBase <- read.csv(args[2], header=F)
perfOther <- read.csv(args[4], header=F)
nameBase <- args[1]
nameOther <- args[3]
benchmarks <- perfBase$V2
stopifnot(benchmarks == perfOther$V2)

swifts <- list(nameBase, nameOther)
result_cols = 3:12

perfBase$swift <- rep(swifts[[1]], nrow(perfBase))
perfOther$swift <- rep(swifts[[2]], nrow(perfOther))

get_perf_matrix <- function(.df) {
    matrix(as.vector(do.call(c, .df[,result_cols])), nrow=nrow(.df))
}

all_perfs <- rbind(perfBase, perfOther)
all_perfs$main_indicator <- apply(get_perf_matrix(all_perfs), 1, min)

for (benchmark in benchmarks) {
    cat("benchmark:", benchmark, "\n===========\n")
    p <- all_perfs[all_perfs$V2 == benchmark,]

    for (swift in swifts) {
        results <- unlist(p[p$swift == swift,][result_cols], use.names=F)

        cat(paste('- with', swift), "\n")
        cat(results, "\n")
        print(summary(results))
    }

    cat(paste("winner: ", p[which.min(p$main_indicator),]$swift), "\n")

    pBase <- p[p$swift == nameBase,]$main_indicator
    pOther <- p[p$swift == nameOther,]$main_indicator

    cat("comparison:", nameBase, "to", nameOther, ":", round(100 * (pOther - pBase)/pBase, 2), "%\n")
    cat("\n")
}
EOF
}

if ! test $# -eq 2; then
    usage
    exit 1
fi

compare_r_script=$(mktemp /tmp/.compare_perf_XXXXXX)
write_compare_r_script "$compare_r_script"

(
cd "$here/.."
compare_args=()
for swift_binary in "$@"; do
    echo "running with $swift_binary"
    perf_file=$(mktemp /tmp/.nio-perf_XXXXXX)
    "$swift_binary" run -c release NIOPerformanceTester | grep ^measuring: | tr : , > "$perf_file" 2>&1
    compare_args+=("$swift_binary")
    compare_args+=("$perf_file")
done

Rscript "$compare_r_script" "${compare_args[@]}"
)

rm "$compare_r_script"
