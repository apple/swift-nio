# Benchmarks

Benchmarks for SwiftNIO

Prerequisite is to have `jemalloc` installed, runs on both Linux and macOS.

Run benchmarks according [to documentation](https://github.com/ordo-one/package-benchmark)

But simple start is `swift package --disable-sandbox benchmark` from the command line.

`--disable-sandbox` required due to network access of some of the benchmarks.
