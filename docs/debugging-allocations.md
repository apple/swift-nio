# How to debug allocation regressions

Usually, your journey will start by detecting that an allocation test regressed. So let's first start by looking at how to run the allocation counter tests.

## Running allocation counter tests

The allocation counter tests are usually run by NIO's integration test framework which lives in `IntegrationTests/`. In there, you first want to identify the test suite and test case that runs all the allocation counter tests. For the `swift-nio` repository that is

    IntegrationTests/tests_04_performance/test_01_allocation_counts.sh

Next to the test case (`test_01_allocation_counts.sh`) that runs the allocation counter tests should be a resource directory which contains the individual allocation counter tests. For `swift-nio` that is

    IntegrationTests/tests_04_performance/test_01_resources

From here on, this document expects that you are within this directory, so you might want to start with

    cd IntegrationTests/tests_04_performance/test_01_resources/

To run all the allocation tests, simply invoke the runner script in there

    ./run-nio-alloc-counter-tests.sh

The invocation of this script will take a while because it has to build all of SwiftNIO in release mode first, then it compiles the integration tests and runs them all, multiple times...

### Understanding the output of the allocation counter tests

The output of this script will look something like

```
- /Users/johannes/devel/swift-nio/IntegrationTests/tests_04_performance/test_01_resources/test_future_lots_of_callbacks.swift
test_future_lots_of_callbacks.remaining_allocations: 0
test_future_lots_of_callbacks.total_allocations: 75001
test_future_lots_of_callbacks.total_allocated_bytes: 4138056
DEBUG: [["remaining_allocations": 0, "total_allocations": 75001, "total_allocated_bytes": 4138056], ["total_allocations": 75001, "remaining_allocations": 0, "total_allocated_bytes": 4138056], ["total_allocated_bytes": 4138056, "total_allocations": 75001, "remaining_allocations": 0], ["total_allocated_bytes": 4138056, "total_allocations": 75001, "remaining_allocations": 0], ["remaining_allocations": 0, "total_allocations": 75001, "total_allocated_bytes": 4138056], ["total_allocations": 75001, "remaining_allocations": 0, "total_allocated_bytes": 4138056], ["total_allocated_bytes": 4138056, "total_allocations": 75001, "remaining_allocations": 0], ["total_allocations": 75001, "total_allocated_bytes": 4138056, "remaining_allocations": 0], ["remaining_allocations": 0, "total_allocations": 75001, "total_allocated_bytes": 4138056], ["total_allocations": 75001, "total_allocated_bytes": 4138056, "remaining_allocations": 0]]
```

with this kind of block repeated for each allocation counter test. Let's go through and understand each line. The first line is the name of the specific allocation test. The most relevant part is the file name (`test_future_lots_of_callbacks.swift`). For this test, we seem to be testing how many allocations futures with many callbacks are doing.

```
- /Users/johannes/devel/swift-nio/IntegrationTests/tests_04_performance/test_01_resources/test_future_lots_of_callbacks.swift
```

Next, we see

```
test_future_lots_of_callbacks.remaining_allocations: 0
test_future_lots_of_callbacks.total_allocations: 75001
test_future_lots_of_callbacks.total_allocated_bytes: 4138056
```

which are the aggregate values. The first line says `remaining_allocations: 0`, which means that this allocation test didn't leak, which is good! Then, we see

    test_future_lots_of_callbacks.total_allocations: 75001

which means that by the end of the test, we saw 75001 allocations in total. As a rule, we usually run the workload of every allocation test 1000 times. That means you want to divide 75001 by the 1000 runs to get the number of allocations per run. In other words: each iteration of this allocation test allocated 75 times. The extra one allocation is just some noise that we have to ignore: these are usually inserted by operations in the Swift runtime that need to initialize some state. In many (especially multi-threaded test cases) there is some noise, which is why we run the workload repeatedly, which makes it easy to tell the signal from the noise.

Finally, we see

    test_future_lots_of_callbacks.total_allocated_bytes: 4138056

Which is the total number of bytes allocated by this test.


Last of all, we see

```
DEBUG: [["remaining_allocations": 0, "total_allocations": 75001, "total_allocated_bytes": 4138056], ["total_allocations": 75001, "remaining_allocations": 0, "total_allocated_bytes": 4138056], ["total_allocated_bytes": 4138056, "total_allocations": 75001, "remaining_allocations": 0], ["total_allocated_bytes": 4138056, "total_allocations": 75001, "remaining_allocations": 0], ["remaining_allocations": 0, "total_allocations": 75001, "total_allocated_bytes": 4138056], ["total_allocations": 75001, "remaining_allocations": 0, "total_allocated_bytes": 4138056], ["total_allocated_bytes": 4138056, "total_allocations": 75001, "remaining_allocations": 0], ["total_allocations": 75001, "total_allocated_bytes": 4138056, "remaining_allocations": 0], ["remaining_allocations": 0, "total_allocations": 75001, "total_allocated_bytes": 4138056], ["total_allocations": 75001, "total_allocated_bytes": 4138056, "remaining_allocations": 0]]
```

which is literally just the exact numbers of each of the 10 runs we considered. Note, the lines are prefixed with `DEBUG:` to make analysis of the output easier, it does _not_ mean we're running in debug mode. If you see a lot of fluctuation between the runs, then the allocation test doesn't allocate deterministically which would be something you want to fix. In the example above, we're totally stable to the last byte of allocated memory, so we have nothing to worry about with this test.

## Important notes

The exact allocation counts are _not_ directly comparable between different operating systems and even different versions of the same operating system. Every new Swift version will also introduce differences (hopefully decreasing over time).

This means that if you get hit by a CI failure, you will have to first reproduce the regression locally by running the allocation counter tests once on `main` and then again on your failing branch.

## Debugging a regression in a particular test

Because it takes quite a while to run the whole allocation counter test suite, there are some shortcuts you definitely want to know about. First, let's have a look at how we can run just single test.


### Running a single test

Running a single test is very straightforward, pass the test's `.swift` file to the runner script. For example:

    ./run-nio-alloc-counter-tests.sh test_future_lots_of_callbacks.swift

You will notice that it now runs faster but also that it still compiles SwiftNIO for every single time you run the program. So that's still rather slow. If you look closely at the output you will notice that it prints messages such as

```
Fetching /private/tmp/.nio_alloc_counter_tests_5jMMhk/swift-nio
Fetching /private/tmp/.nio_alloc_counter_tests_5jMMhk/HookedFunctions
Fetching /private/tmp/.nio_alloc_counter_tests_5jMMhk/AtomicCounter
```

If you change your working directory to common directory above (`/private/tmp/.nio_alloc_counter_tests_5jMMhk`), then you will find a regular Swift package there and you can just re-run the allocation counter tests using

```
cd /tmp/.nio_alloc_counter_tests_5jMMhk
swift run -c release
```

which should run very quickly. But _do not_ forget to pass `-c release`, otherwise the results will be meaningless.

### Debugging with other tools

Often, you will want to use external tools such as Instruments or `dtrace` to analyse why a performance test regressed. Unfortunately, that is a little harder than you might expect because to implement the allocation tests, the allocation counter test framework actually [hijacks](https://github.com/apple/swift-nio/blob/main/IntegrationTests/tests_04_performance/test_01_resources/README.md) functions like `malloc` and `free`. The counting of allocations happens in the hijacked or 'hooked' functions.
To use an external memory analysis tool, it's best to not do the hooking and fortunately it's very straightforward to switch the hooking off.

To disable the hooking, run the runner script with `-- -n` followed by the file name of the test you would like to debug. For example

    ./run-nio-alloc-counter-tests.sh -- -n test_future_lots_of_callbacks.swift

When you run this, you will notice that every allocation counter test now outputs

```
Fetching /private/tmp/.nio_alloc_counter_tests_0UDNXS/HookedFunctions
Fetching /private/tmp/.nio_alloc_counter_tests_0UDNXS/swift-nio
Fetching /private/tmp/.nio_alloc_counter_tests_0UDNXS/AtomicCounter
[...]
test_future_lots_of_callbacks.total_allocations: 0
test_future_lots_of_callbacks.remaining_allocations: 0
test_future_lots_of_callbacks.total_allocated_bytes: 0
DEBUG: [["total_allocations": 0, "remaining_allocations": 0, "total_allocated_bytes": 0], ["remaining_allocations": 0, "total_allocations": 0, "total_allocated_bytes": 0], ["total_allocations": 0, "total_allocated_bytes": 0, "remaining_allocations": 0], ["total_allocated_bytes": 0, "total_allocations": 0, "remaining_allocations": 0], ["total_allocations": 0, "total_allocated_bytes": 0, "remaining_allocations": 0], ["total_allocated_bytes": 0, "remaining_allocations": 0, "total_allocations": 0], ["total_allocations": 0, "total_allocated_bytes": 0, "remaining_allocations": 0], ["total_allocated_bytes": 0, "remaining_allocations": 0, "total_allocations": 0], ["remaining_allocations": 0, "total_allocated_bytes": 0, "total_allocations": 0], ["total_allocated_bytes": 0, "total_allocations": 0, "remaining_allocations": 0]]
```

See all the zeroes? Those are all zero because the hooking is disabled. In this mode the output itself is not very useful but you can now switch to using other tools like Intruments or `dtrace` to debug your allocations.

As explained before, you can change your working directory in the temporary directory (for example `cd /private/tmp/.nio_alloc_counter_tests_0UDNXS`) and invoke `swift run -c release` from there to run the allocation counter benchmark. Note that if you disabled hooking (by passing `-- -n`) it will still print only zeroes.

### Debugging with Instruments

1. Start Instruments
2. Choose the "Allocations" instrument
3. Tap the executable selector in the toolbar
4. Click "Choose Target..."
5. Tick "Show Hidden Files"
6. Press Cmd+Shift+G
7. Enter the temporary directory path of a non-hooked version of the allocation counter tests (for example `/private/tmp/.nio_alloc_counter_tests_0UDNXS`)
8. Select `.build/release/`
9. Find the binary that is named like your allocation counter test (eg. `test_lots_of_future_callbacks`)
10. Click "Choose"
11. Press the record button

Now you should have a full Instruments allocations trace of the test run. To make sense of what's going on, switch the allocation lifespan from "Created & Persisted" to "Created & Destroyed". After that you should be able to see the type of the allocation and how many times it got allocated. Clicking on the little arrow next to the type name will reveal each individual allocation of this type and the responsible stack trace.

### Debugging with `malloc-aggregation.d` or `malloc-aggreation.bt`

SwiftNIO ships a `dtrace` script called `dev/malloc-aggregation.d` which can give you an aggregation of all allocations by stack trace, and an equivalent `bpftrace` script called `dev/malloc-aggregation.bt`. This means that you will see the stack trace of each allocation that happened and how many times this particular stack trace allocated.

Here's an example of how to use the `dtrace` script:

```
sudo ~/path/to/swift-nio/dev/malloc-aggregation.d -c .build/release/test_future_lots_of_callbacks
```

The `bpftrace` script can be invoked very similarly:

```
sudo ~/path/to/swift-nio/dev/malloc-aggregation.bt -c .build/release/test_future_lots_of_callbacks
```

However, for `bpftrace` it tends to work better if pid-based tracing is used instead. This is because `bpftrace` has a [known limitation where symbolication fails if the process being traced has existed before `bpftrace` does](https://github.com/bpftrace/bpftrace/issues/2118#issuecomment-1008694821). This can still be resolved using tools like `llvm-symbolizer`, but it's trickier.

The output will look something like

```
[...]
              libsystem_malloc.dylib`malloc
              libswiftCore.dylib`swift_slowAlloc+0x19
              libswiftCore.dylib`swift_allocObject+0x27
              test_1_reqs_1000_conn`SelectableEventLoop.run()+0x231
              test_1_reqs_1000_conn`closure #1 in static MultiThreadedEventLoopGroup.setupThreadAndEventLoop(name:selectorFactory:initializer:)+0x106
              test_1_reqs_1000_conn`partial apply for closure #1 in static MultiThreadedEventLoopGroup.setupThreadAndEventLoop(name:selectorFactory:initializer:)+0x2d
              test_1_reqs_1000_conn`thunk for @escaping @callee_guaranteed (@guaranteed NIOThread) -> ()+0xf
              test_1_reqs_1000_conn`partial apply for thunk for @escaping @callee_guaranteed (@guaranteed NIOThread) -> ()+0x11
              test_1_reqs_1000_conn`closure #1 in static ThreadOpsPosix.run(handle:args:detachThread:)+0x1e4
              libsystem_pthread.dylib`_pthread_start+0x94
              libsystem_pthread.dylib`thread_start+0xf
           231000

```

repeated many times. Each block means that the specific stack trace is responsible for some number of allocations: in the example above, `231000` allocations. Remember that the allocation counter tests run each test 11 times (1 warm up run and 10 measured runs), so this means that in each test run, the above stack trace allocated 21000 times. Also remember that we usually run the workload we want to test 1000 times. That means that in the real world, the above stack trace accounts for 21 out of the total number of allocations (231000 allocations / 11 runs / 1000 executions per run = 21).

When you are looking at allocations in the setup of the test the numbers may be split into one allocation set of 10000 and another of 1000 - for measured code vs warm up run.

The output from `malloc-aggreation.d` can also be diffed using the `stackdiff-dtrace.py` script. This can be helpful to track down where additional allocations were made. Right now this strategy doesn't work for `bpftrace`, but a simple modification to the `stackdiff-dtrace` script should enable it.

The `stdout` from `malloc-aggregation.d` for the two runs to compare should be written to files, and then passsed to `stackdiff-dtrace.py`:

```bash
~/path/to/swift-nio/dev/stackdiff-dtrace.py stack_aggregation.old stack_aggregation.new
```

Where `stack_aggregation.old` and `stack_aggregation.new` are the two outputs from `malloc-aggregation.d` to compare. The script will output the aggregated stacks which appear: 

- only in `stack_aggregation.old`,
- only in `stack_aggregation.new`, and
- any differences in numbers for stacks that appear in both.

Similar stack traces will be aggregated into a headline number for matching but where different the full stack traces which made up the collection will be printed indented.

Allocations of less than 1000 in number are ignored - as the tests all run multiples of 1000 runs any values below this are almost certainly from setup in libraries we are using rather than as a consequence of our measured run.

Let's look at some output.

```
### only in AFTER
11000
libsystem_malloc.dylib`malloc
libswiftCore.dylib`swift_slowAlloc
libswiftCore.dylib`swift_allocObject
test_1_reqs_1000_conn`$s3NIO7Channel_pxq_q0_r1_lyypypAA15EventLoopFutureCyytGIsegnnr_Iegnr_AaB_pypypAEIegnno_Ieggo_TR
test_1_reqs_1000_conn`$s3NIO7Channel_pypypAA15EventLoopFutureCyytGIegnno_Ieggo_AaB_pxq_q0_r1_lyypypAEIsegnnr_Iegnr_TR
test_1_reqs_1000_conn`$s3NIO7Channel_pypypAA15EventLoopFutureCyytGIegnno_Ieggo_AaB_pxq_q0_r1_lyypypAEIsegnnr_Iegnr_TRTA
test_1_reqs_1000_conn`$s3NIO7Channel_pypypAA15EventLoopFutureCyytGIegnno_Ieggo_AaB_pxq_q0_r1_lyypypAEIsegnnr_Iegnr_TRTA.18
test_1_reqs_1000_conn`$s3NIO7Channel_pxq_q0_r1_lyypypAA15EventLoopFutureCyytGIsegnnr_Iegnr_AaB_pypypAEIegnno_Ieggo_TR

    11000
        libsystem_malloc.dylib`malloc
        libswiftCore.dylib`swift_slowAlloc+0x19
        libswiftCore.dylib`swift_allocObject+0x27
        test_1_reqs_1000_conn`$s3NIO7Channel_pxq_q0_r1_lyypypAA15EventLoopFutureCyytGIsegnnr_Iegnr_AaB_pypypAEIegnno_Ieggo_TR+0x54
        test_1_reqs_1000_conn`$s3NIO7Channel_pypypAA15EventLoopFutureCyytGIegnno_Ieggo_AaB_pxq_q0_r1_lyypypAEIsegnnr_Iegnr_TR+0x20
        test_1_reqs_1000_conn`$s3NIO7Channel_pypypAA15EventLoopFutureCyytGIegnno_Ieggo_AaB_pxq_q0_r1_lyypypAEIsegnnr_Iegnr_TRTA+0x11
        test_1_reqs_1000_conn`$s3NIO7Channel_pypypAA15EventLoopFutureCyytGIegnno_Ieggo_AaB_pxq_q0_r1_lyypypAEIsegnnr_Iegnr_TRTA.18+0x9
        test_1_reqs_1000_conn`$s3NIO7Channel_pxq_q0_r1_lyypypAA15EventLoopFutureCyytGIsegnnr_Iegnr_AaB_pypypAEIegnno_Ieggo_TR+0x2e
        test_1_reqs_1000_conn`specialized applyNext #1 () in ChannelOptions.Storage.applyAllChannelOptions(to:)+0x1a9
        test_1_reqs_1000_conn`closure #2 in ServerBootstrap.bind0(makeServerChannel:_:)+0xf8
        test_1_reqs_1000_conn`partial apply for closure #2 in ServerBootstrap.bind0(makeServerChannel:_:)+0x39
        test_1_reqs_1000_conn`partial apply for thunk for @escaping @callee_guaranteed () -> (@owned EventLoopFuture<Channel>, @error @owned Error)+0x14
        test_1_reqs_1000_conn`thunk for @escaping @callee_guaranteed () -> (@owned EventLoopFuture<Channel>, @error @owned Error)partial apply+0x9
        test_1_reqs_1000_conn`closure #1 in EventLoop.submit<A>(_:)+0x3c
        test_1_reqs_1000_conn`partial apply for thunk for @escaping @callee_guaranteed () -> ()+0x11
        test_1_reqs_1000_conn`partial apply for thunk for @escaping @callee_guaranteed () -> (@out ())+0x11
        test_1_reqs_1000_conn`partial apply for closure #3 in SelectableEventLoop.run()+0x11
        test_1_reqs_1000_conn`thunk for @callee_guaranteed () -> (@error @owned Error)+0xc
        test_1_reqs_1000_conn`partial apply for thunk for @callee_guaranteed () -> (@error @owned Error)+0x11
        test_1_reqs_1000_conn`thunk for @callee_guaranteed () -> (@error @owned Error)partial apply+0x9
[...]

### only in BEFORE
11000
libsystem_malloc.dylib`malloc
libswiftCore.dylib`swift_slowAlloc
libswiftCore.dylib`swift_allocObject
test_1_reqs_1000_conn`$s3NIO7Channel_pxq_q0_r1_lyypypAA15EventLoopFutureCyytGIsegnnr_Iegnr_AaB_pypypAEIegnno_Ieggo_TR
test_1_reqs_1000_conn`$s3NIO7Channel_pypypAA15EventLoopFutureCyytGIegnno_Ieggo_AaB_pxq_q0_r1_lyypypAEIsegnnr_Iegnr_TR
test_1_reqs_1000_conn`$s3NIO7Channel_pypypAA15EventLoopFutureCyytGIegnno_Ieggo_AaB_pxq_q0_r1_lyypypAEIsegnnr_Iegnr_TRTA
test_1_reqs_1000_conn`$s3NIO7Channel_pypypAA15EventLoopFutureCyytGIegnno_Ieggo_AaB_pxq_q0_r1_lyypypAEIsegnnr_Iegnr_TRTA.33
test_1_reqs_1000_conn`$s3NIO7Channel_pxq_q0_r1_lyypypAA15EventLoopFutureCyytGIsegnnr_Iegnr_AaB_pypypAEIegnno_Ieggo_TR

    11000
        libsystem_malloc.dylib`malloc
        libswiftCore.dylib`swift_slowAlloc+0x19
        libswiftCore.dylib`swift_allocObject+0x27
        test_1_reqs_1000_conn`$s3NIO7Channel_pxq_q0_r1_lyypypAA15EventLoopFutureCyytGIsegnnr_Iegnr_AaB_pypypAEIegnno_Ieggo_TR+0x54
        test_1_reqs_1000_conn`$s3NIO7Channel_pypypAA15EventLoopFutureCyytGIegnno_Ieggo_AaB_pxq_q0_r1_lyypypAEIsegnnr_Iegnr_TR+0x20
        test_1_reqs_1000_conn`$s3NIO7Channel_pypypAA15EventLoopFutureCyytGIegnno_Ieggo_AaB_pxq_q0_r1_lyypypAEIsegnnr_Iegnr_TRTA+0x11
        test_1_reqs_1000_conn`$s3NIO7Channel_pypypAA15EventLoopFutureCyytGIegnno_Ieggo_AaB_pxq_q0_r1_lyypypAEIsegnnr_Iegnr_TRTA.33+0x9
        test_1_reqs_1000_conn`$s3NIO7Channel_pxq_q0_r1_lyypypAA15EventLoopFutureCyytGIsegnnr_Iegnr_AaB_pypypAEIegnno_Ieggo_TR+0x2e
        test_1_reqs_1000_conn`specialized applyNext #1 () in ChannelOptions.Storage.applyAllChannelOptions(to:)+0x1a9
        test_1_reqs_1000_conn`closure #2 in ServerBootstrap.bind0(makeServerChannel:_:)+0xf8
        test_1_reqs_1000_conn`partial apply for closure #2 in ServerBootstrap.bind0(makeServerChannel:_:)+0x39
        test_1_reqs_1000_conn`partial apply for thunk for @escaping @callee_guaranteed () -> (@owned EventLoopFuture<Channel>, @error @owned Error)+0x14
        test_1_reqs_1000_conn`thunk for @escaping @callee_guaranteed () -> (@owned EventLoopFuture<Channel>, @error @owned Error)partial apply+0x9
        test_1_reqs_1000_conn`closure #1 in EventLoop.submit<A>(_:)+0x3c
        test_1_reqs_1000_conn`partial apply for thunk for @escaping @callee_guaranteed () -> ()+0x11
        test_1_reqs_1000_conn`partial apply for thunk for @escaping @callee_guaranteed () -> (@out ())+0x11
        test_1_reqs_1000_conn`partial apply for closure #3 in SelectableEventLoop.run()+0x11
        test_1_reqs_1000_conn`thunk for @callee_guaranteed () -> (@error @owned Error)+0xc
        test_1_reqs_1000_conn`partial apply for thunk for @callee_guaranteed () -> (@error @owned Error)+0x11
        test_1_reqs_1000_conn`thunk for @callee_guaranteed () -> (@error @owned Error)partial apply+0x9
[...]
```

These stacks are only *slighly* different; differing only in the name similar to `$s3NIO7Channel_pxq_q0_r1_lyypypAA15EventLoopFutureCyytGIsegnnr_Iegnr_AaB_pypypAEIegnno_Ieggo_TR`. They're otherwise the same so we can ignore them and look at more output.

```
### only in AFTER
[... (previously dismissed stacktrace)]

2000
libsystem_malloc.dylib`malloc
libswiftCore.dylib`swift_slowAlloc
libswiftCore.dylib`swift_allocObject
test_1_reqs_1000_conn`doRequests(group:number:)
test_1_reqs_1000_conn`closure #1 in run(identifier:)
test_1_reqs_1000_conn`partial apply for closure #1 in measureOne #1 (throwAway:_:) in measureAll(_:)
test_1_reqs_1000_conn`partial apply for thunk for @callee_guaranteed () -> (@error @owned Error)
test_1_reqs_1000_conn`thunk for @callee_guaranteed () -> (@error @owned Error)partial apply

    1000
        libsystem_malloc.dylib`malloc
        libswiftCore.dylib`swift_slowAlloc+0x19
        libswiftCore.dylib`swift_allocObject+0x27
        test_1_reqs_1000_conn`doRequests(group:number:)+0x66
[...]
        
    1000
        libsystem_malloc.dylib`malloc
        libswiftCore.dylib`swift_slowAlloc+0x19
        libswiftCore.dylib`swift_allocObject+0x27
        test_1_reqs_1000_conn`doRequests(group:number:)+0x1c4
[...]

### only in BEFORE
[... (previously dismissed stacktrace)]

### different numbers
before: 10000, after: 20000
  AFTER
    10000
        libsystem_malloc.dylib`malloc
        libswiftCore.dylib`swift_slowAlloc+0x19
        libswiftCore.dylib`swift_allocObject+0x27
        test_1_reqs_1000_conn`doRequests(group:number:)+0x66
[...]
```

Now we see there's another stacktrace in the `AFTER` section which has no corresponding stacktrace in `BEFORE`. From the stack we can see it's originating from `doRequests(group:number:)`. In this instance we were working on options applied in this function so it appears we have added allocations.  We have also increased the number of allocations which are reported in the different numbers section where stack traces have been paired but with different numbers of allocations.

### Debugging with 'heaptrack'

In some cases we don't have access to Linux kernel headers, which prevents us from using `bpftrace`, but there is the [heaptrack](https://github.com/KDE/heaptrack) tool which supports diff analysis of two versions.

Tested on Ubuntu 20.04 (and likely working on other distributions) Install it with:

```
sudo apt-get install heaptrack
```

Then using the instructions previously, you need to build the test without hooks such that heaptrack can hook instead, e.g.:

```
cd IntegrationTests/tests_04_performance/test_01_resources/
./run-nio-alloc-counter-tests.sh -- -n test_1000_autoReadGetAndSet.swift 
```

and then cd to the temp directory from the output (find the tmp directory as above), e.g.:

```
cd /tmp/.nio_alloc_counter_tests_5jMMhk
```

Finally, run the binary with heaptrack two times — first we do it for `main` to get a baseline:
```
ubuntu@ip-172-31-25-161 /t/.nio_alloc_counter_tests_GRusAy> SWIFTNIO_URING_DISABLED=1 heaptrack .build/x86_64-unknown-linux-gnu/release/test_1000_autoReadGetAndSet
heaptrack output will be written to "/tmp/.nio_alloc_counter_tests_GRusAy/heaptrack.test_1000_autoReadGetAndSet.84341.gz"
starting application, this might take some time...
SWIFTNIO_URING_DISABLED set, disabling liburing.
test_1000_autoReadGetAndSet.total_allocations: 0
test_1000_autoReadGetAndSet.total_allocated_bytes: 0
test_1000_autoReadGetAndSet.remaining_allocations: 0
DEBUG: [["total_allocations": 0, "total_allocated_bytes": 0, "remaining_allocations": 0], ["remaining_allocations": 0, "total_allocated_bytes": 0, "total_allocations": 0], ["total_allocations": 0, "total_allocated_bytes": 0, "remaining_allocations": 0], ["remaining_allocations": 0, "total_allocated_bytes": 0, "total_allocations": 0], ["remaining_allocations": 0, "total_allocated_bytes": 0, "total_allocations": 0], ["remaining_allocations": 0, "total_allocations": 0, "total_allocated_bytes": 0], ["total_allocated_bytes": 0, "total_allocations": 0, "remaining_allocations": 0], ["total_allocated_bytes": 0, "total_allocations": 0, "remaining_allocations": 0], ["remaining_allocations": 0, "total_allocations": 0, "total_allocated_bytes": 0], ["total_allocations": 0, "remaining_allocations": 0, "total_allocated_bytes": 0]]
free(): invalid pointer
Aborted (core dumped)
heaptrack stats:
    allocations:              319347
    leaked allocations:       107
    temporary allocations:    68
Heaptrack finished! Now run the following to investigate the data:

  heaptrack --analyze "/tmp/.nio_alloc_counter_tests_GRusAy/heaptrack.test_1000_autoReadGetAndSet.84341.gz"
```
Then run it a second time for the feature branch:
```
ubuntu@ip-172-31-25-161 /t/.nio_alloc_counter_tests_ARusXy> heaptrack .build/x86_64-unknown-linux-gnu/release/test_1000_autoReadGetAndSet
heaptrack output will be written to "/tmp/.nio_alloc_counter_tests_GRusAy/heaptrack.test_1000_autoReadGetAndSet.84372.gz"
starting application, this might take some time...
test_1000_autoReadGetAndSet.remaining_allocations: 0
test_1000_autoReadGetAndSet.total_allocations: 0
test_1000_autoReadGetAndSet.total_allocated_bytes: 0
DEBUG: [["remaining_allocations": 0, "total_allocations": 0, "total_allocated_bytes": 0], ["total_allocated_bytes": 0, "total_allocations": 0, "remaining_allocations": 0], ["total_allocated_bytes": 0, "remaining_allocations": 0, "total_allocations": 0], ["total_allocations": 0, "total_allocated_bytes": 0, "remaining_allocations": 0], ["total_allocations": 0, "remaining_allocations": 0, "total_allocated_bytes": 0], ["remaining_allocations": 0, "total_allocations": 0, "total_allocated_bytes": 0], ["total_allocations": 0, "total_allocated_bytes": 0, "remaining_allocations": 0], ["remaining_allocations": 0, "total_allocated_bytes": 0, "total_allocations": 0], ["remaining_allocations": 0, "total_allocations": 0, "total_allocated_bytes": 0], ["remaining_allocations": 0, "total_allocated_bytes": 0, "total_allocations": 0]]
free(): invalid pointer
Aborted (core dumped)
heaptrack stats:
    allocations:              673989
    leaked allocations:       117
    temporary allocations:    341011
Heaptrack finished! Now run the following to investigate the data:

  heaptrack --analyze "/tmp/.nio_alloc_counter_tests_GRusAy/heaptrack.test_1000_autoReadGetAndSet.84372.gz"
ubuntu@ip-172-31-25-161 /t/.nio_alloc_counter_tests_GRusAy> 
```
Here we could see that we had 673989 allocations in the feature branch version and 319347 in `main`, so clearly a regression.

Finally, we can analyze the output as a diff from these runs using `heaptrack_print`:

```
heaptrack_print -T -d heaptrack.test_1000_autoReadGetAndSet.84341.gz heaptrack.test_1000_autoReadGetAndSet.84372.gz | swift demangle
```
`-T` gives us the temporary allocations (as it in this case was not a leak, but a transient alloaction - if you have leaks remove `-T`).

The output can be quite long, but in this case as we look for transient allocations, scroll down to:

```
MOST TEMPORARY ALLOCATIONS
307740 temporary allocations of 290324 allocations in total (106.00%) from
swift_slowAlloc
  in /home/ubuntu/bin/usr/lib/swift/linux/libswiftCore.so
43623 temporary allocations of 44553 allocations in total (97.91%) from:
    swift_allocObject
      in /home/ubuntu/bin/usr/lib/swift/linux/libswiftCore.so
    NIO.ServerBootstrap.(bind0 in _C131C0126670CF68D8B594DDFAE0CE57)(makeServerChannel: (NIO.SelectableEventLoop, NIO.EventLoopGroup) throws -> NIO.ServerSocketChannel, _: (NIO.EventLoop, NIO.ServerSocketChannel) -> NIO.EventLoopFuture<()>) -> NIO.EventLoopFuture<NIO.Channel>
      at /home/ubuntu/swiftnio/swift-nio/Sources/NIO/Bootstrap.swift:295
      in /tmp/.nio_alloc_counter_tests_GRusAy/.build/x86_64-unknown-linux-gnu/release/test_1000_autoReadGetAndSet
    merged NIO.ServerBootstrap.bind(host: Swift.String, port: Swift.Int) -> NIO.EventLoopFuture<NIO.Channel>
      in /tmp/.nio_alloc_counter_tests_GRusAy/.build/x86_64-unknown-linux-gnu/release/test_1000_autoReadGetAndSet
    NIO.ServerBootstrap.bind(host: Swift.String, port: Swift.Int) -> NIO.EventLoopFuture<NIO.Channel>
      in /tmp/.nio_alloc_counter_tests_GRusAy/.build/x86_64-unknown-linux-gnu/release/test_1000_autoReadGetAndSet
    Test_test_1000_autoReadGetAndSet.run(identifier: Swift.String) -> ()
      at /tmp/.nio_alloc_counter_tests_GRusAy/Sources/Test_test_1000_autoReadGetAndSet/file.swift:24
      in /tmp/.nio_alloc_counter_tests_GRusAy/.build/x86_64-unknown-linux-gnu/release/test_1000_autoReadGetAndSet
    main
      at Sources/bootstrap_test_1000_autoReadGetAndSet/main.c:18
      in /tmp/.nio_alloc_counter_tests_GRusAy/.build/x86_64-unknown-linux-gnu/release/test_1000_autoReadGetAndSet
22208 temporary allocations of 22276 allocations in total (99.69%) from:
    swift_allocObject
      in /home/ubuntu/bin/usr/lib/swift/linux/libswiftCore.so
    generic specialization <Swift.UnsafeBufferPointer<Swift.Int8>> of Swift._copyCollectionToContiguousArray<A where A: Swift.Collection>(A) -> Swift.ContiguousArray<A.Element>
      in /home/ubuntu/bin/usr/lib/swift/linux/libswiftCore.so
    Swift.String.utf8CString.getter : Swift.ContiguousArray<Swift.Int8>
      in /home/ubuntu/bin/usr/lib/swift/linux/libswiftCore.so
    NIO.URing.getEnvironmentVar(Swift.String) -> Swift.String?
      at /home/ubuntu/swiftnio/swift-nio/Sources/NIO/LinuxURing.swift:291
      in /tmp/.nio_alloc_counter_tests_GRusAy/.build/x86_64-unknown-linux-gnu/release/test_1000_autoReadGetAndSet
    NIO.URing._debugPrint(@autoclosure () -> Swift.String) -> ()
      at /home/ubuntu/swiftnio/swift-nio/Sources/NIO/LinuxURing.swift:297
...
22196 temporary allocations of 22276 allocations in total (99.64%) from:
```

And here we could fairly quickly see that the transient extra allocations was due to extra debug printing and querying of environment variables:

```
NIO.URing.getEnvironmentVar(Swift.String) -> Swift.String?
  at /home/ubuntu/swiftnio/swift-nio/Sources/NIO/LinuxURing.swift:291
  in /tmp/.nio_alloc_counter_tests_GRusAy/.build/x86_64-unknown-linux-gnu/release/test_1000_autoReadGetAndSet
NIO.URing._debugPrint(@autoclosure () -> Swift.String) -> ()
```

And this code will be removed before final integration of the feature branch, so the diff will go away.
