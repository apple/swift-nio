# Running Allocation Counting Tests

This document explains the different type of allocation counting tests and how
to run them.

## Overview

Allocations are expensive so are often a good proxy for measuring performance in
an application: reducing unnecessary allocations _typically_ leads to an
increase in performance. SwiftNIO has a number of tests which record allocations
and check the results against a threshold. These are run as part of CI and help
us to avoid introducing allocation regressions.

SwiftNIO uses two frameworks for running allocation tests:

1. The [`package-benchmark`](https://github.com/ordo-one/package-benchmark)
   package.
2. A homegrown allocation counting framework.

## Running package-benchmark benchmarks

The `package-benchmark` benchmarks live in the `Benchmarks` directory of the
`swift-nio` repository. To run the benchmarks you'll need to install `jemalloc`,
refer to the instructions in the `package-benchmark` [Getting
Started](https://swiftpackageindex.com/ordo-one/package-benchmark/documentation/benchmark/gettingstarted#Installing-Prerequisites-and-Platform-Support)
guide to do this.

To run all the benchmarks without checking against the thresholds run the
following command from the `Benchmarks` directory:

```sh
$ swift package benchmark
```

To list the available benchmarks run:

```sh
$ swift package benchmark list
```

To run a subset of benchmarks you can provide a regular expression to the
`--filter` option. For example to run just the "WaitOnPromise" benchmark:


```sh
$ swift package benchmark --filter WaitOnPromise
```

Each benchmark has a threshold associated with it. These are stored in the
`Benchmarks/Thresholds` directory. There are thresholds for each version of
Swift that SwiftNIO supports.

To run the benchmarks and check against the thresholds, in this case the nightly
builds of Swift's `main` branch you can run:

```sh
$ swift package benchmark threshold check --path Thresholds/nightly-main
```

Sometimes you'll need to run a benchmark _without_ invoking it via `swift
package benchmark`. The easiest way to do this is to first invoke `swift
package benchmark` and then run the benchmark binary which was built as a
side effect:

```sh
$ ./.build/release/NIOCoreBenchmarks --filter WaitOnPromise
```

## Running the homegrown benchmarks

Most of SwiftNIO's allocation counting tests are written using its own framework
which predates `package-benchmark`. The source for the framework lives in
`IntegrationTests/allocation-counter-tests-framework` and is used across the
various `swift-nio-*` repositories and more besides. In the `swift-nio`
repository the tests live in
`IntegrationTests/tests_04_performance/test_01_resources`.

The following commands assume your current working directory is
`IntegrationTests/tests_04_performance/test_01_resources`.

To run all tests written for this framework:

```sh
$ ./run-nio-alloc-counter-tests.sh
```

The invocation of this script will take a while because it has to build all of
SwiftNIO in release mode first, then it compiles the integration tests and runs
them all, multiple times.

To run a single test specify the file containing it as an argument to the
script:

```sh
$ ./run-nio-alloc-counter-tests.sh test_future_lots_of_callbacks.swift
```

You'll notice that when you run the script that it builds SwiftNIO and
the test each time. In the output you should see some lines like:

```
...
Fetching /private/tmp/.nio_alloc_counter_tests_5jMMhk/swift-nio
Fetching /private/tmp/.nio_alloc_counter_tests_5jMMhk/HookedFunctions
Fetching /private/tmp/.nio_alloc_counter_tests_5jMMhk/AtomicCounter
...
```

The `/private/tmp/.nio_alloc_counter_tests_5jMMhk` directory contains
a regular Swift package which you can modify to iterate more quickly, 
just don't forget to build it whith `-c release`!

### Understanding the output

The output of the script will look something like:

```
- /Users/johannes/devel/swift-nio/IntegrationTests/tests_04_performance/test_01_resources/test_future_lots_of_callbacks.swift
test_future_lots_of_callbacks.remaining_allocations: 0
test_future_lots_of_callbacks.total_allocations: 75001
test_future_lots_of_callbacks.total_allocated_bytes: 4138056
DEBUG: [["remaining_allocations": 0, "total_allocations": 75001, "total_allocated_bytes": 4138056], ["total_allocations": 75001, "remaining_allocations": 0, "total_allocated_bytes": 4138056], ["total_allocated_bytes": 4138056, "total_allocations": 75001, "remaining_allocations": 0], ["total_allocated_bytes": 4138056, "total_allocations": 75001, "remaining_allocations": 0], ["remaining_allocations": 0, "total_allocations": 75001, "total_allocated_bytes": 4138056], ["total_allocations": 75001, "remaining_allocations": 0, "total_allocated_bytes": 4138056], ["total_allocated_bytes": 4138056, "total_allocations": 75001, "remaining_allocations": 0], ["total_allocations": 75001, "total_allocated_bytes": 4138056, "remaining_allocations": 0], ["remaining_allocations": 0, "total_allocations": 75001, "total_allocated_bytes": 4138056], ["total_allocations": 75001, "total_allocated_bytes": 4138056, "remaining_allocations": 0]]
```

with this kind of block repeated for each allocation counter test. Let's go
through and understand each line. The first line is the name of the specific
allocation test. The most relevant part is the file name
(`test_future_lots_of_callbacks.swift`). For this test, we seem to be testing
how many allocations futures with many callbacks are doing.

```
- /Users/johannes/devel/swift-nio/IntegrationTests/tests_04_performance/test_01_resources/test_future_lots_of_callbacks.swift
```

Next, we see

```
test_future_lots_of_callbacks.remaining_allocations: 0
test_future_lots_of_callbacks.total_allocations: 75001
test_future_lots_of_callbacks.total_allocated_bytes: 4138056
```

which are the aggregate values. The first line says `remaining_allocations: 0`,
which means that this allocation test didn't leak, which is good! Then, we see

```
test_future_lots_of_callbacks.total_allocations: 75001
```

which means that by the end of the test, we saw 75001 allocations in total. As a
rule, we usually run the workload of every allocation test 1000 times. That
means you want to divide 75001 by the 1000 runs to get the number of allocations
per run. In other words: each iteration of this allocation test allocated 75
times. The extra one allocation is just some noise that we have to ignore: these
are usually inserted by operations in the Swift runtime that need to initialize
some state. In many (especially multi-threaded test cases) there is some noise,
which is why we run the workload repeatedly, which makes it easy to tell the
signal from the noise.

Finally, we see

```
test_future_lots_of_callbacks.total_allocated_bytes: 4138056
```

Which is the total number of bytes allocated by this test.

Last of all, we see

```
DEBUG: [["remaining_allocations": 0, "total_allocations": 75001, "total_allocated_bytes": 4138056], ["total_allocations": 75001, "remaining_allocations": 0, "total_allocated_bytes": 4138056], ["total_allocated_bytes": 4138056, "total_allocations": 75001, "remaining_allocations": 0], ["total_allocated_bytes": 4138056, "total_allocations": 75001, "remaining_allocations": 0], ["remaining_allocations": 0, "total_allocations": 75001, "total_allocated_bytes": 4138056], ["total_allocations": 75001, "remaining_allocations": 0, "total_allocated_bytes": 4138056], ["total_allocated_bytes": 4138056, "total_allocations": 75001, "remaining_allocations": 0], ["total_allocations": 75001, "total_allocated_bytes": 4138056, "remaining_allocations": 0], ["remaining_allocations": 0, "total_allocations": 75001, "total_allocated_bytes": 4138056], ["total_allocations": 75001, "total_allocated_bytes": 4138056, "remaining_allocations": 0]]
```

which are just the exact numbers of each of the 10 runs we considered.
Note, the lines are prefixed with `DEBUG:` to make analysis of the output
easier, it does _not_ mean we're running in debug mode. If you see a lot of
fluctuation between the runs, then the allocation test doesn't allocate
deterministically which would be something you want to fix. In the example
above, we're totally stable to the last byte of allocated memory, so we have
nothing to worry about with this test.
