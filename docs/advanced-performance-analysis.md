# Advanced performance analysis for CPU-bound programs

Most performance problems can be handily debugged with [Instruments, `perf`, or FlameGraphs](https://github.com/swift-server/guides/blob/main/docs/performance.md). At times however, there are changes in performance that are very hard to understand and sometimes very counter intuitive.

## Motivating example (feel free to skip)
A motivating example is [this pull request](https://github.com/apple/swift-nio/pull/1733) which is supposed to improve the performance of `ByteToMessageDecoder`s in very specific cases. The expectation would be that most performance tests remain the same and everything that uses a `ByteToMessageDecoder` either remains the same or becomes a little faster. Of course, all the low-level microbenchmarks that don't even use `ByteToMessageDecoder`s should be totally unaffected by this change.

For the most part that was the case, except for two benchmarks in SwiftNIO's performance test suite for which the [results were](https://github.com/apple/swift-nio/pull/1733#issuecomment-766917189) very unexpected:

<table border="1">
  <tr>
    <td>benchmark name</td>
    <td>run time with PR</td>
    <td>run time before PR</td>
    <td>which is faster</td>
    <td>difference</td>
  </tr>
  <tr>
    <td>circular_buffer_into_byte_buffer_1kb</td>
    <td>0.05089386</td>
    <td>0.041163118</td>
    <td>previous</td>
    <td>23%</td>
  </tr>
  <tr>
    <td>circular_buffer_into_byte_buffer_1mb</td>
    <td>0.094321349</td>
    <td>0.082286637</td>
    <td>previous</td>
    <td>14%</td>
  </tr>
</table>

This means that for whatever reason, the totally unrelated benchmarks `circular_buffer_into_byte_buffer_*` got _slower_ by 23% and 14% respectively (measured in wall clock seconds) despite using none of the changed code.

## Wall clock time

To start out, we need to verify if the benchmark results are stable regarding wall clock time. If there is too much variation, then it is likely that too much I/O or allocations etc are involved. If a benchmark is unstable because of I/O or allocations, there are better tools available than what is discussed here, for example `strace`, Instrument's "Allocations" instrument, or Xcode's Memory Graph Debugger. This document solely discusses _CPU-bound_ and mostly single-threaded performance analysis, ie. you should see one CPU core pegged at 100% for the whole duration of the benchmark.

## Executed CPU instructions

If you have two versions of a program, one faster and one slower and you want to find out what is going on, then often it makes sense to look at the number of CPU instructions executed during the benchmark.

On Linux -- assuming you have access to the PMU (Performance Monitoring Unit) -- this is rather straightforward

    perf stat -- ./benchmark arguments

The output will look similar to

```
 Performance counter stats for './my-benchmark args':

            449.96 msec task-clock                #    1.001 CPUs utilized
                36      context-switches          #    0.080 K/sec
                 9      cpu-migrations            #    0.020 K/sec
              2989      page-faults               #    0.007 M/sec
        1736698259      cycles                    #    3.860 GHz
          53504877      stalled-cycles-frontend   #    3.08% frontend cycles idle
        5927885177      instructions              #    3.41  insn per cycle
                                                  #    0.01  stalled cycles per insn
        1422566509      branches                  # 3161.555 M/sec
            375326      branch-misses             #    0.03% of all branches

       0.449450377 seconds time elapsed

       0.442788000 seconds user
       0.008050000 seconds sys
```

First, we can confirm that it is nicely CPU bound (`1.001 CPUs utilized`).

We can also see that we executed about 5.9B instructions during this benchmark run. The number of instructions executed itself is not very meaningful but it can be very useful when comparing between versions of the same code. For example, let's assume we changed some code and want to confirm in a benchmark that indeed we have made it faster, then it can be very useful to see that we have also reduced the number of instructions.

With `perf` you could run `perf stat -e instructions -- ./benchmark-before-change` and `perf stat -e instructions -- ./benchmark-after-change` and confirm that:

1. The runtime (_time elapsed_) has gone down and
2. the number of instructions executed has gone down too.

Note that the time it takes to run an instruction varies wildly so it is in theory possible to reduce the number of instructions but make performance actually worse. An example would be if you traded a lot of simple arithmetic for memory accesses. Said that, in most cases where you reduced the number of instructions significantly, you will also see an improvement in the actual runtime. As a control, the number of instructions per cycle can also be useful as it would go down if you traded faster instructions for slower instructions.

Another place where instruction counts come in very handy is when you see this maybe impossible-sounding situation: the run time varies significantly but the number of executed instructions is _the same_. The motivating example is exactly this situation: The code executed is the _same_, confirmed by manually checking the generated assembly for the code run as well as checking that the number of instructions is almost equal. Because manual assembly analysis can easily go wrong, it's advisable to compare the number of executed instructions even if you convinced yourself that the executed code is the same. Of course, there are other options like single-stepping in a debugger but that gets tedious quickly. If the executed code and the inputs are the same, then the number of executed instructions should also be the same (ie. < 0.01% variance).

That begs the question: What can we do if we have the runtime differs despite running the exact same instructions? Assuming the code is CPU-bound, the answer is probably that the CPU cannot execute the instructions at the same velocity because it internally has to wait for something (such as memory, more instructions being decoded, another resource, ...). Many of these situations are referred to as CPU stalls.

## CPU stalls

When ending up in situations where a difference in run time is not clearly reflected in the instructions executed, it may be worth looking into CPU stalls. Modern CPUs may be unable to reach their full speed for a variety of reasons. For example it could be that the instruction decoder can't decode the instructions as fast as they could execute (be retired). Or instructions may have to wait to be executed because the data required is slow to load (cache misses etc).

The easiest way to look into such micro-architectural issues are through the CPU's performance counters and with `perf` they're quite easy to access.

A good starting point for tracing stalls may be

    perf stat -e instructions,stalled-cycles-frontend,uops_executed.stall_cycles,resource_stalls.any,cycle_activity.stalls_mem_any -- ./benchmark

Which instructs `perf` to collect the following performance counters:

- `instructions`: The number of CPU instructions executed,
- `stalled-cycles-frontend`: cycles where nothing happened because instructions cannot be decoded fast enough,
- `uops_executed.stall_cycles`: the number of cycles where no (micro-)operations were dispatched to be executed on a given core,
- `resource_stalls.any`: Stalls that occurred because the backend had to wait for resources (eg. memory)
- `cycle_activity.stalls_mem_any`: execution stalls while memory subsystem has an outstanding load.

which will yield output similar to

```
 Performance counter stats for './fast circular_buffer_into_byte_buffer_1kb':

        5927396603      instructions
          64091849      stalled-cycles-frontend
          38429768      uops_executed.stall_cycles
          13278071      resource_stalls.any
          22148955      cycle_activity.stalls_mem_any

       0.452895518 seconds time elapsed
```

And just like for the instruction counts, the absolute counts of the stalled cycles are not that important, but they can be very important as a comparison. Going back to the motivating example, where we could see:

fast version (`perf stat -e counters... -- ./fast`):

```
 Performance counter stats for './fast circular_buffer_into_byte_buffer_1kb':

        5927396603      instructions
          34307940      uops_executed.stall_cycles
          13109779      resource_stalls.any
          18148622      cycle_activity.stalls_mem_any

       0.409785892 seconds time elapsed
```

slow version (`perf stat -e counters... -- ./slow`):

```
 Performance counter stats for './slow circular_buffer_into_byte_buffer_1kb':

        5927358294      instructions
         308782310      uops_executed.stall_cycles
          14159547      resource_stalls.any
         288072686      cycle_activity.stalls_mem_any

       0.510635133 seconds time elapsed

```

What we can immediately see is that `resource_stalls.any` is pretty much the same in both cases, but `uops_executed.stall_cycles` and `cycle_activity.stalls_mem_any` are about an order of magnitude higher for the slow case. Remember, this is with the number of instructions being almost the same.

So in this case, we would have identified that the slowdown comes from us getting a lot of "stall cycles" in the CPU. Those are cycles where the CPU was free to run some (micro-)instructions but could not. Unfortunately, from this picture alone, it is unclear _why_ exactly the CPU couldn't actually run some more (micro-)operations. We’ve only learned a little so far, we need to dig deeper.

One strategy is to run

    perf list | less

and in there, search for "stall" (using `/stall`) and "penalty". This will yield some results of available performance counters that allow you to identify which particular stall it may be. It's worth to know that you can specify a bunch of them in one command line (comma separated). Figuring out which ones to choose is really an exercise in brute force with a little educated guessing, there aren't _that many_ such counters so it won't take you too long.  In the motivating example, the culprit turned out to be `dsb2mite_switches.penalty_cycles`

```
 Performance counter stats for './fast circular_buffer_into_byte_buffer_1kb':

           9943811      dsb2mite_switches.penalty_cycles

       0.408032273 seconds time elapsed
```

vs

```
 Performance counter stats for './slow circular_buffer_into_byte_buffer_1kb':

         229285609      dsb2mite_switches.penalty_cycles

       0.511033898 seconds time elapsed
```

The names of these stalls/penalties can be quite opaque and understanding what exactly is going on can be rather hard without a pretty good understanding of how a particular CPU micro-architecture works. Nevertheless, being able to pinpoint why a slowdown happens can be very important as it may give information on what to change in the code.

In case you're wondering what `dsb2mite_switches.penalty_cycles` is, a web search revealed a nicely written [blogpost](https://easyperf.net/blog/2018/01/18/Code_alignment_issues) which discusses something very similar. Bottom line is that modern Intel CPUs have a MITE (Micro-operation Translation Engine) which seems to read the instruction stream in 16 byte chunks. So if the alignment of your code is changed (for example by adding/removing an unrelated function to/from your binary) you may incur a penalty if your instructions aren't aligned by 16 bytes (remember, Intel instructions are variable length). This does sound scary (and for some code it is) but the good news is that this should _very rarely_ matter outside of micro-benchmarks. If your whole run time is doing exactly what that micro-benchmark is doing, you should probably care. But most real-world code does much more and more diverse work than some arbitrary micro-benchmarks. So in this particular example we can safely ignore the "regression" which was just unlucky placement of the hot function in the binary. Nevertheless it was important to understand why the regression happened so we could safely decide it does not matter in this instance.

## The bad news: PMU access

Unfortunately, in some environments like Docker for Mac and other solutions relying on virtualisation it can be hard to get access to the PMU (the CPU's performance measuring unit). Check out this [guide](https://github.com/swift-server/guides/blob/main/docs/linux-perf.md#getting-perf-to-work) for tips on getting `perf` with PMU support to work in your environment.
