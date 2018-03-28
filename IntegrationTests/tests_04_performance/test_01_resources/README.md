# Allocation Counting Test

This briefly describes how the allocation counting test works.

## How does it work?

Basically it's the world's cheapest allocation counter, actually it is a memory `free` counter rather than a `malloc` counter. Why does it count `free` and not `malloc`? Because it's much easier. A correct implementation of `malloc` without relying on the system's `malloc` is non-trivial, an implementation of `free` however is trivial: just do nothing. Sure, you wouldn't want to run a real-world program with a free function that doesn't free the memory as you would run out of memory really quickly. For a short benchmark however it doesn't matter. The only thing that the hooked `free` function does is incrementing an atomic integer variable (representing the number of allocations) than can be read out elsewhere later.

### How is the free function hooked?

Usually in UNIX it's enough to just define a function

```C
void free(void *ptr) { ... }
```

in the main binary and all modules will use this `free` function instead of the real one from the `libc`. For Linux, this is exactly what we're doing, the `bootstrap` binary defines such a `free` function in its `main.c`. On Darwin (macOS/iOS/...) however that is not the case and you need to use [dyld's interpose feature](https://books.google.co.uk/books?id=K8vUkpOXhN4C&lpg=PA73&ots=OMjhRWWwUu&dq=dyld%20interpose&pg=PA73#v=onepage&q=dyld%20interpose&f=false). The odd thing is that dyld's interposing _only_ works if it's in a `.dylib` and not from a binary's main executable. Therefore we need to build a slightly strange SwiftPM package:

- `bootstrap`: The main executable's main module (written in C) so we can hook the `free` function on Linux.
- `BootstrapSwift`: A SwiftPM module (written in Swift) called in from `bootstrap` which implements the actual SwiftNIO benchmark (and therefore depends on the `NIO` module).
- `HookedFree`: A separate SwiftPM package that builds a shared library (`.so` on Linux, `.dylib` on Darwin) which contains the `replacement_free` function which just increments an atomic integer representing the number of allocations. On Darwin, we use `DYLD_INTERPOSE` in this module, interposing libc's `free` with our `replacement_free`. This needs to be a separate SwiftPM package as otherwise its code would just live inside of the `bootstrap` executable and the dyld interposing feature wouldn't work.
- `AtomicCounter`: SwiftPM package (written in C) that implements the atomic counters. It needs to be a separate package as both `BoostrapSwift` (to read the allocation counter) as well as `HookedFree` (to increment the allocation counter) depend on it.

## What benchmark is run?

We run a single TCP connection over which 1000 HTTP requests are made by a client written in NIO, responded to by a server also written in NIO. We re-run the benchmark 10 times and return the lowest number of allocations that has been made.

## Why do I have to set a baseline?

By default this test should always succeed as it doesn't actually compare the number of allocations to a certain number. The reason is that this number varies ever so slightly between operating systems and Swift versions. At the time of writing on macOS we got roughly 326k allocations and on Linux 322k allocations for 1000 HTTP requests & responses. To set a baseline simply run

```bash
export MAX_ALLOCS_ALLOWED_1000_reqs_1_conn=327000
```

or similar to set the maximum number of allocations allowed. If the benchmark exceeds these allocations the test will fail.
