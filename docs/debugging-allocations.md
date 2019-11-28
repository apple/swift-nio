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

This means that if you get hit by a CI failure, you will have to first reproduce the regression locally by running the allocation counter tests once on `master` and then again on your failing branch.

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

Often, you will want to use external tools such as Instruments or `dtrace` to analyse why a performance test regressed. Unfortunately, that is a little harder than you might expect because to implement the allocation tests, the allocation counter test framework actually [hijacks](https://github.com/apple/swift-nio/blob/master/IntegrationTests/tests_04_performance/test_01_resources/README.md) functions like `malloc` and `free`. The counting of allocations happens in the hijacked or 'hooked' functions.
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

### Debugging with `malloc-aggregation.d` (macOS only)

SwiftNIO ships a `dtrace` script called `dev/malloc-aggregation.d` which can give you an aggregation of all allocations by stack trace. This means that you will see the stack trace of each allocation that happened and how many times this particular stack trace allocated.

Here's an example of how to use this script:

```
sudo ~/path/to/swift-nio/dev/malloc-aggregation.d -c .build/release/test_future_lots_of_callbacks
```

The output will look something like

```
[...]

              libsystem_malloc.dylib`malloc
              libswiftCore.dylib`swift_slowAlloc+0x19
              libswiftCore.dylib`_swift_allocObject_(swift::TargetHeapMetadata<swift::InProcess> const*, unsigned long, unsigned long)+0x14
              test_future_lots_of_callbacks`specialized closure #1 in EventLoopFuture.flatMap<A>(file:line:_:)+0xc0
              test_future_lots_of_callbacks`specialized CallbackList._run()+0xd4e
              test_future_lots_of_callbacks`doThenAndFriends #1 (loop:) in closure #1 in run(identifier:)+0x201
              test_future_lots_of_callbacks`specialized closure #1 in measure(identifier:_:)+0x53
              test_future_lots_of_callbacks`partial apply for closure #1 in measureOne #1 (_:) in measureAll(_:)+0x11
              test_future_lots_of_callbacks`partial apply for thunk for @callee_guaranteed () -> (@error @owned Error)+0x11
              libswiftObjectiveC.dylib`autoreleasepool<A>(invoking:)+0x2e
              test_future_lots_of_callbacks`measureAll(_:)+0x159
              test_future_lots_of_callbacks`measureAndPrint(desc:fn:)+0x2d
              test_future_lots_of_callbacks`main+0x9
              libdyld.dylib`start+0x1
              test_future_lots_of_callbacks`0x1
            30000
```

repeated many times. Each block means that the specific stack trace is responsible for some number of allocations: in the example above, `30000` allocations. Remember that the allocation counter tests run each test 10 times, so this means that in each test run, the above stack trace allocated 3000 times. Also remember that we usually run the workload we want to test 1000 times. That means that in the real world, the above stack trace accounts for 3 out of the 75 total allocations (30000 allocations / 10 runs / 1000 executions per run = 3).
