#  SwiftNIO io_uring support status [Linux]

## Background
Linux has fairly recently received a new asynchrounus I/O interface — `io_uring` — that allows high-performance AIO with a minimum amount of system calls. Some background information at [LWN](https://lwn.net/Articles/810414/) and [kernel.dk](https://kernel.dk/io_uring.pdf)

## Current status and supported platforms
SwiftNIO has basic support for using `io_uring` as a notification mechanism. `io_uring` is available on Linux kernels starting from 5.1 and requires support for the POLL operations. SwiftNIO optionally supports multishot polls and poll updates through a configuration option - these are new interfaces that are expected to available from the future release 5.13 (as of this writing). The `io_uring` implementation has primarily been tested on version 5.12rc.

## Performance expectations
Currently the `io_uring` implementation does not yet use the underlying interface to its full potential - it is only used for polling and not yet for asynchronous operation of send/recv/read/write. This means performance characteristics currently will be similar to the default  `epoll()` (or slightly worse), but you should test for your specific use case as YMMV. This is expected to change in the future as the `io_uring` interface is used more extensively.

## How to use and requirements
To enable `io_uring`, SwiftNIO needs to be built and run on a machine that has the [liburing](https://github.com/axboe/liburing) library installed (typically in `/usr/local`) - if SwiftNIO has been built on a machine without liburing — or if it is not available on the production machine — it will fall back on using epoll.

## Configuration options
There are a number of runtime options that system operations staff may want to tune - these are set as environment variables and outlined here:

### `SWIFTNIO_URING_ENABLED`
If set (including empty value), io_uring will be used if supported on the platform, unless `SWIFTNIO_URING_DISABLED` is set which will take precedence.

### `SWIFTNIO_URING_DISABLED`
If set (including empty value), io_uring will be disabled. This takes precedence over `SWIFTNIO_URING_ENABLED` and is primaily useful for testing purposes.

### `SWIFTNIO_URING_USE_NEW_POLL`
If set (including empty value), we will use multishot polls and poll mask updates instead of singleshot polls. This feature is due to be implemented in the 5.13 Linux kernel and **should only be enabled if you know your deployment platform supports it**, process may crash otherwise. By default, SwiftNIO will use single-shot polls

### `SWIFTNIO_URING_RING_SIZE`
Should be set to an integer that is a power-of-two - default is 4096 and the current allowed range is 4...65536. You may need to tune the size of your ring depending on the usage pattern to avoid deadlocks  (for some degenarate tests a larger value may be needed if e.g. more operations are done during a single event loop tick than the ring size). For most real-world use cases the default should work fine.

### `SWIFTNIO_IORING_SETUP_SQPOLL`
If set (including empty value), a kernel polling thread will be set up for reaping SQE:s, which fundamentally removes all system calls from the submission path for poll operations. A minimal custom ring instance will be set up which is used to share a single kernel polling thread amongst all event loops. This polling thread will go to sleep after a period of time if no event are being processed, in which case the next poll operation will do a system call which starts up a new poll thread. Currently there are no facilities to pin this thread but it is planned as a future improvement. On older Linux kernels elevated privileges are required for this option to succeed, but from 5.12+ this can be done with normal user privs.

## Roadmap
The initial support for `io_uring` is primarily intended to give people interested in it that ability to try it out and provide feedback - in the future the expectation is to add full support for `io_uring` which is expected to give significant performance improvements on Linux systems supporting it.
The idea is also to fine tune settings for e.g. SQPOLL such that it can be pinned on a specific CPU.
