#  SwiftNIO io_uring support status [Linux]

## Background
Linux has fairly recently received a new asynchrounus I/O interface — `io_uring` — that allows high-performance AIO with a minimum amount of system calls. Some background information at [LWN](https://lwn.net/Articles/810414/) and [kernel.dk](https://kernel.dk/io_uring.pdf)

## Current status and supported platforms
SwiftNIO has basic support for using `io_uring` as a notification mechanism. `io_uring` is available on Linux kernels starting from 5.1 and requires support for the POLL operations. SwiftNIO optionally supports multishot polls and poll updates through a configuration option - these are new interfaces that are expected to available from the future release 5.13 (as of this writing). The `io_uring` implementation has primarily been tested on version 5.12rc.

## Performance expectations
Currently the `io_uring` implementation does not yet use the underlying interface to its full potential - it is only used for polling and not yet for asynchronous operation of send/recv/read/write. This means performance characteristics currently will be similar to the default  `epoll()` (or slightly worse), but you should test for your specific use case as YMMV. This is expected to change in the future as the `io_uring` interface is used more extensively.

## How to use and requirements
To enable `io_uring`, SwiftNIO needs to be built and run on a machine that has the [liburing](https://github.com/axboe/liburing) library installed (typically in `/usr/local`). If built with liburing, it must be available and work on the production machine.

To build SwiftNIO so it uses io_uring instead of epoll, you must specify additional flags when building:
`swift build -Xcc -DSWIFTNIO_USE_IO_URING=1 -Xlinker -luring -Xswiftc -DSWIFTNIO_USE_IO_URING`

To build it so also use the new poll update / multishot polls (will need kernel 5.13+) you need to do:
`swift build -Xcc -DSWIFTNIO_USE_IO_URING=1 -Xlinker -luring -Xswiftc -DSWIFTNIO_USE_IO_URING -Xswiftc -DSWIFTNIO_IO_URING_MULTISHOT`

## Debug output
There are currently three debug outputs that can be compiled in (e.g. to verify that `liburing` is used as expected and for development troubleshooting)
`-Xswiftc -DSWIFTNIO_IO_URING_DEBUG_SELECTOR`
`-Xswiftc -DSWIFTNIO_IO_URING_DEBUG_URING`
`-Xswiftc -DSWIFTNIO_IO_URING_DEBUG_DUMP_CQE`

## Roadmap
The initial support for `io_uring` is primarily intended to give people interested in it that ability to try it out and provide feedback - in the future the expectation is to add full support for `io_uring` which is expected to give significant performance improvements on Linux systems supporting it.
The idea is also to add SQPOLL together with fine tune settings such that it can be pinned on a specific CPU.

