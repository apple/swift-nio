//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Stacks
import Testing

struct DTraceParserTests {
    @Test
    func parsing() throws {
        // Real input but modified to be a lot shorter.
        let input = """

            =====
            This will collect stack shots of allocations and print it when you exit dtrace.
            So go ahead, run your tests and then press Ctrl+C in this window to see the aggregated result
            =====
            20896284696


                          libsystem_malloc.dylib`malloc_type_calloc
                          libobjc.A.dylib`class_createInstance+0x4c
                          libdispatch.dylib`_os_object_alloc_realized+0x20
                          libdispatch.dylib`_dispatch_client_callout+0x10
                          libdispatch.dylib`_dispatch_once_callout+0x20
                          libswiftCore.dylib`swift_dynamicCast+0x60
                          libswiftCore.dylib`_print_unlocked<A, B>(_:_:)+0x2e4
                           13

                          libsystem_malloc.dylib`malloc_type_malloc
                          libswiftCore.dylib`swift_allocObject+0x88
                          libswiftCore.dylib`_ContiguousArrayBuffer.init(_uninitializedCount:minimumCapacity:)+0xa0
                          do-some-allocs`specialized static do_some_allocs.main()+0x5c
                          do-some-allocs`do_some_allocs_main+0xc
                          dyld`start+0x1870
                        10000

            """

        let lines = input.split(separator: "\n").map { String($0) }
        let stacks = DTraceParser.parse(lines: lines)

        try #require(stacks.count == 2)

        let stack0 = stacks[0]
        let expected0 = WeightedStack(
            lines: [
                "libsystem_malloc.dylib`malloc_type_calloc",
                "libobjc.A.dylib`class_createInstance",
                "libdispatch.dylib`_os_object_alloc_realized",
                "libdispatch.dylib`_dispatch_client_callout",
                "libdispatch.dylib`_dispatch_once_callout",
                "libswiftCore.dylib`swift_dynamicCast",
                "libswiftCore.dylib`_print_unlocked<A, B>(_:_:)",
            ],
            allocations: 13
        )
        #expect(stack0 == expected0)

        let stack1 = stacks[1]
        let expected1 = WeightedStack(
            lines: [
                "libsystem_malloc.dylib`malloc_type_malloc",
                "libswiftCore.dylib`swift_allocObject",
                "libswiftCore.dylib`_ContiguousArrayBuffer.init(_uninitializedCount:minimumCapacity:)",
                "do-some-allocs`specialized static do_some_allocs.main()",
                "do-some-allocs`do_some_allocs_main",
                "dyld`start",
            ],
            allocations: 10000
        )
        #expect(stack1 == expected1)
    }
}
