# Debugging Allocation Regressions

This document explains different approaches to debugging allocation regressions.

## Overview

If you're not familiar with running SwiftNIO's allocation counting tests then
take a look at <doc:Running-Alloction-Counting-Tests> first.

The exact allocation counts are _not_ directly comparable between different
operating systems and even different versions of the same operating system.
Every new Swift version will also introduce differences (hopefully decreasing
over time).

This means that if you get hit by a CI failure, you will have to first reproduce
the regression locally by running the allocation counter tests once on `main`
and then again on your failing branch. Sometimes the allocation will be platform
specific and you may have to reproduce it in a container.

How you diagnose regressions depends on the nature of the change. It may be
possible to diagnose regressions from inspection; did the change introduce any
unnecessary allocations? Are there any intermediate allocations (such as from a
collection resizing where capacity could've been reserved) which could be
avoided?

Most cases aren't so straightforward and require a different approach, such as:
- Looking at the allocation traces in Instruments (macOS only)
- Diffing allocation traces

## Instruments

To look at allocation traces in Instruments:

1. Start Instruments
2. Choose the "Allocations" instrument
3. Tap the executable selector in the toolbar
4. Click "Choose Target..."
5. Select the binary for the test
6. Click "Choose"
7. Press the record button

Now you should have a full Instruments allocations trace of the test run. To
make sense of what's going on, switch the allocation lifespan from "Created &
Persisted" to "Created & Destroyed". After that you should be able to see the
type of the allocation and how many times it got allocated. Clicking on the
little arrow next to the type name will reveal each individual allocation of
this type and the responsible stack trace.

## Collecting allocation traces

As you're looking for an allocation regression you should have two versions of
the binary you're debugging: a before and an after. A useful way to find the
regression is to collect and compare all of the allocation stacks for each
version of the program.

How you collect the stacks depends on the platform you're investigating.
SwiftNIO provides scripts for `dtrace` (macOS) and `bpftrace` (Linux) to collect
stacks that lead to allocations. You can also use `heaptrack` on Linux where
`bpftrace` isn't available. The following sections explain how to collection
allocation traces using each tool.

### DTrace (macOS)

On macOS you can use `dtrace`. SwiftNIO provides the `malloc-aggregation.d`
script in the `dev` directory for collecting stacks. You can run it with:

```
sudo ./malloc-aggregation.d -c your-executable
```

To make analysis easier you can demangle the symbols with `swift demangle`:

```
sudo ./malloc-aggregation.d -c your-executable | swift demangle
```

### BFPTrace (Linux)

On Linux, and where available, you can use `bpftrace`. SwiftNIO provides the
`malloc-aggregation.bt` script in the `dev` directory for collecting stacks.

You'll need to install `bpftrace` first, on Ubuntu you can run:

```
apt-get update && apt-get install -y bpftrace
```

The script is very similar to the DTrace script and you can run it by passing
your executable as an argument, for example:

```
sudo ./malloc-aggregation.bt -c your-executable
```

However, `bpftrace` tends to work better if PID-based tracing is used instead.
This is because `bpftrace` has a [known limitation where symbolication fails if
the process being traced has existed before `bpftrace`
does](https://github.com/bpftrace/bpftrace/issues/2118#issuecomment-1008694821).
This can still be resolved using tools like `llvm-symbolizer`, but it's
trickier.

You can pass the PID of your program to the script via the `-p` option, for
example:

```
sudo ./malloc-aggregation.bt -p <PID>
```

You can start your executable in the background and capture the PID to pass
to `malloc-aggreation.bt` using:

```
your-executable & PID=$! && sudo ./malloc-aggregation.bt -p $PID
```

### Heaptrack (Linux)

In some cases we don't have access to Linux kernel headers, which prevents us
from using `bpftrace`, but there is the
[heaptrack](https://github.com/KDE/heaptrack) tool which can also capture
allocation stacks.

To install heaptrack on Ubuntu run:

```
apt-get update && apt-get install -y heaptrack
```

Getting allocation stacks from `heaptrack` is a two-step process. First you need
to run your binary with `heaptrack`:

```
heaptrack /path/to/executable_to_test
```

This will produce a `.gz` file which `heaptrack_print` can analyze:

```
heaptrack_print \
    --print-allocators yes \
    --print-peaks no \
    --print-temporary no \
    --peak-limit 1000 \
    --sub-peak-limit 1000 \
    heaptrack_capture.gz
```

There are many options for `heaptrack_print`, the command above will print out
the top allocating stacks. Note `--peak-limit` and `--sub-peak-limit`, these
default to quite low values so raising them is important to avoid information
loss that can make analysis more difficult.

You can also pipe the result of `heaptrack_print` through `swift demangle` to
make analysis easier.

## Diffing allocation traces

Once you've captured two allocation traces for your program you can diff them to
work out where any regression was introduced. Each of the tools outlined
previously produce output in different formats although they are broadly similar
to:


```
...
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
...
```

The output will contain many blocks like this. Each block means that the
specific stack trace is responsible for some number of allocations: in the
example above, 231000 allocations.

The output from `bpftrace` and `heaptrack` will differ slightly to this. To make
analysis easier we built a tool to parse and analyze the stacks.

### stackdiff

The `stackdiff` tool is a CLI tool for parsing and analyzing stack traces
collected by `dtrace`, `bpftrace`, and `heaptrack`. It's available in the
`dev/stackdiff` directory of the `swift-nio` repository. You can build it from
the `stackdiff` directiroy with `swift build -c release`. The tool has three
subcommands:

1. `dump`,
2. `diff`, and
3. `merge`.

#### stackdiff dump

The `dump` subcommand parses and prints stacks collected via `dtrace`,
`bpftrace`, or `heaptrack`. You must provide the stack traces as an argument
along with the format of the input. For example, if you collected the allocation
traces using DTrace into `allocs.txt` you should run:

```
stackdiff dump --format dtrace allocs.txt
```

By default only stacks with 1000 allocations or more are included. You can
change this with `--min-allocations`:

```
stackdiff dump --format dtrace --min-allocations 10000 allocs.txt
```

You can also filter traces so that only stacks containing a given string are
included:

```
stackdiff dump --format dtrace --filter swift_slowAlloc allocs.txt
```

See the help with `stackdiff dump --help` to learn about other options.

#### stackdiff diff

The `diff` subcommand parses stacks from two input files and prints the stacks
which are unique to each input file as well as the stacks which are common to
both input files but have differing allocation counts. You can apply the same
options as the `dump` command.

To print the diff between two `heaptrack` outputs use:

```
stackdiff diff --format heaptrack before.txt after.txt
```

This will print out a few different sections:
1. Allocation traces present only in "before.txt",
2. Allocation traces present only in "after.txt",
3. Allocation traces present only in "before.txt" and "after.txt" but with
   differing allocation counts.
4. A summary of the allactions.

Using this information can help you to narrow down where the allocation was
introduced. In some cases there will be many stacks which are unique to each
file but are subtly different. These often hide the true cause of the
regression. The `merge` command makes finding these differences easier.

#### stackdiff merge

The `merge` subcommand is much like `diff` but interactively allows you to pair
up unique stacks from one file with those from another. This is done by
computing a textual similarity between stacks and offering them to you to either
accept or reject. Once you've matched analyzed the unique traces across the
files you should be left with the _actual_ difference.

You can call `merge` like you do for `diff`:

```
stackdiff merge --format heaptrack before.txt after.txt
```

You'll first be presented with a summary of the differences between the two
inputs:

```
Input A
- File: before.txt
- Allocations: 623000
- Stacks: 373
- Stacks only in A: 22

Input B
- File: after.txt
- Allocations: 624000
- Stacks: 374
- Stacks only in B: 23

Allocation delta (A-B): -1000

About to start merging stacks, hit enter to continue ...
```

The tool refers to inputs `A` and `B` when merging, these correspond to the
files printed in the summary (i.e. the first and second positional arguments
passed to `merge`.) For each it prints the total number of allocations which
haven't been filtered out in each file, the number of stacks in each file, and
the unique stacks in each. In this case there are 22 stacks in `A` which aren't
present in `B`, and `23` stacks in `B` which aren't in `A`. It's likely that 22
of the stacks are the practically speaking the same with one additional stack in
`B`. You can also see that the allocation delta is -1000, meaning that `B` has
1000 allocations more than `A`.

You'll then need to hit enter to start merging stacks. When you do, you'll be
presented with output like this:

```
Finding candidates for stack 1 of 22 (S1) from A only ...
Looking at candidate stack 1 of 23 (S2) ...

Allocations:
       |     A |      B |    Net
    S1 | 10000 |      0 |  10000
    S2 |     0 | -10000 | -10000
 Total | 10000 | -10000 |      0

Stack similarity: 0.7441860465116279

S1| ...skipping 3 common lines...
S1| libswiftCore.dylib`_ContiguousArrayBuffer.init(_uninitializedCount:minimumCapacity:)
S1| ...skipping 3 common lines...

S2| ...skipping 3 common lines...
S2| libswiftCore.dylib`_allocateStringStorage(codeUnitCapacity:)
S2| libswiftCore.dylib`_StringGuts.reserveCapacity(_:)
S2| libswiftCore.dylib`String.init(repeating:count:)
S2| ...skipping 3 common lines...

Accept ([y]es/no/skip/expand)?:
```

The first two lines tell you your progress, in this case that you're looking at
the first stack which is only present in `A` and evaluating it against the first
candidate stack:

```
Finding candidates for stack 1 of 22 (S1) from A only ...
Looking at candidate stack 1 of 23 (S2) ...
```

After this is a table indicating the allocations and where they come from:

```
Allocations:
       |     A |      B |    Net
    S1 | 10000 |      0 |  10000
    S2 |     0 | -10000 | -10000
 Total | 10000 | -10000 |      0
```

The `S1` and `S2` labels apply to the two stacks we're looking at and the two
`A` and `B` columns indicate how many allocations from that stack are associated
with the two input files. Allocations from `B` are always treated as negative
(we're diffing `A` and `B` so conceptually subtracting `B` from `A`.)

Below the table you can see the similarity score of 0.74:

```
Stack similarity: 0.7441860465116279
```

Scores above 0.9 are considered strong matches, below 0.55 are weak.

The two stacks `S1` and `S2` are printed next:

```
S1| ...skipping 3 common lines...
S1| libswiftCore.dylib`_ContiguousArrayBuffer.init(_uninitializedCount:minimumCapacity:)
S1| ...skipping 3 common lines...

S2| ...skipping 3 common lines...
S2| libswiftCore.dylib`_allocateStringStorage(codeUnitCapacity:)
S2| libswiftCore.dylib`_StringGuts.reserveCapacity(_:)
S2| libswiftCore.dylib`String.init(repeating:count:)
S2| ...skipping 3 common lines...
```

Their common prefix and suffix are hidden to make their differences more
obvious. Finally you're asked for input:

```
Accept ([y]es/no/skip/expand)?:
```

If you think the stacks are effectively the same then enter `y` or `yes` and hit
enter (or just hit enter, as this is the default option). If you don't think the
stacks match up then enter `n` or `no` and hit enter, you'll then be presented
with a similar output but with a different candidate for `S2`. If there are no
candidates remaining or you enter `s` or `skip` then `S1` will not be paired and
you'll be presented with the next stack for `S1`. Finally, you can else enter
`e` or `expand` to expand out the common lines.

Once you've finished merging stacks you'll be presented with all the unmerged
stacks, in other words, those which haven't been paired up between `A` and `B`
and common stacks which have a non-zero allocation count:

```
Finished merging stacks, removing stacks with net zero allocations.
Stacks remaining: 1
Net allocations: -1000

ALLOCATIONS: -1000
libsystem_malloc.dylib`malloc_type_malloc
libswiftCore.dylib`swift::swift_slowAllocTyped(unsigned long, unsigned long, unsigned long long)
libswiftCore.dylib`swift_allocObject
libswiftCore.dylib`_allocateStringStorage(codeUnitCapacity:)
libswiftCore.dylib`_StringGuts.reserveCapacity(_:)
libswiftCore.dylib`String.init(repeating:count:)
do-some-allocs`specialized static do_some_allocs.main()
do-some-allocs`do_some_allocs_main
dyld`start
```

This means that the one remaining stack was from `B` and has 1000 allocations.
