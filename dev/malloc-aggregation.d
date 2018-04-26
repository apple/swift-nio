#!/usr/sbin/dtrace -q -s
/*===----------------------------------------------------------------------===*
 *
 *  This source file is part of the SwiftNIO open source project
 *
 *  Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
 *  Licensed under Apache License v2.0
 *
 *  See LICENSE.txt for license information
 *  See CONTRIBUTORS.txt for the list of SwiftNIO project authors
 *
 *  SPDX-License-Identifier: Apache-2.0
 *
 *===----------------------------------------------------------------------===*/

/*
 * example invocation:
 *   sudo dev/malloc-aggregation.d -c .build/release/NIOHTTP1Server
 */

::BEGIN {
    printf("\n\n");
    printf("=====\n");
    printf("This will collect stack shots of allocations and print it when ");
    printf("you exit dtrace.\n");
    printf("So go ahead, run your tests and then press Ctrl+C in this window ");
    printf("to see the aggregated result\n");
    printf("=====\n");
}

pid$target::malloc:entry, pid$target::posix_memalign:entry, pid$target::realloc:entry, pid$target::reallocf:entry, pid$target::calloc:entry, pid$target::valloc:entry {
    @malloc_calls[ustack()] = count();
}

::END {
    printa(@malloc_calls);
}
