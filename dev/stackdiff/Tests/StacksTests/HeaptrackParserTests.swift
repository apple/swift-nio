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

struct HeaptrackParserTests {
    @Test
    func parsing() throws {
        // Real input but modified to be a lot shorter.
        let input = """
            reading file "heaptrack.simple-handshake.a.gz" - please wait, this might take some time...
            Debuggee command was: ./.build/release/simple-handshake
            finished reading file, now analyzing data:

            MOST CALLS TO ALLOCATION FUNCTIONS
            488872 calls to allocation functions with 28.16K peak consumption from
            CNIOBoringSSL_OPENSSL_malloc
              at Sources/CNIOBoringSSL/crypto/mem.cc:249
              in /code/.build/aarch64-unknown-linux-gnu/release/simple-handshake
            3000 calls with 80B peak consumption from:
                CNIOBoringSSL_OPENSSL_zalloc
                  at Sources/CNIOBoringSSL/crypto/mem.cc:266
                  in /code/.build/aarch64-unknown-linux-gnu/release/simple-handshake
                CNIOBoringSSL_ASN1_item_ex_new
                  at Sources/CNIOBoringSSL/crypto/asn1/tasn_new.cc:153
                  in /code/.build/aarch64-unknown-linux-gnu/release/simple-handshake
                ASN1_template_new(ASN1_VALUE_st**, ASN1_TEMPLATE_st const*)
                  at Sources/CNIOBoringSSL/crypto/asn1/tasn_new.cc:236
                  in /code/.build/aarch64-unknown-linux-gnu/release/simple-handshake
                CNIOBoringSSL_ASN1_item_ex_new
                  at Sources/CNIOBoringSSL/crypto/asn1/tasn_new.cc:161
                asn1_item_ex_d2i(ASN1_VALUE_st**, unsigned char const**, long, ASN1_ITEM_st const*, int, int, char, crypto_buffer_st*, int)
                  at Sources/CNIOBoringSSL/crypto/asn1/tasn_dec.cc:378
                  in /code/.build/aarch64-unknown-linux-gnu/release/simple-handshake
                static simple_handshake.SimpleHandshake.$main() throws -> ()
                  at //<compiler-generated>:40
                simple_handshake_main
                  at /code/Sources/simple-handshake/SimpleHandshake.swift:0
                0xffff935b73fa
                  in /lib/aarch64-linux-gnu/libc.so.6
                __libc_start_main
                  in /lib/aarch64-linux-gnu/libc.so.6
            2000 calls with 96B peak consumption from:
                CNIOBoringSSL_ASN1_STRING_type_new
                  at Sources/CNIOBoringSSL/crypto/asn1/asn1_lib.cc:329
                  in /code/.build/aarch64-unknown-linux-gnu/release/simple-handshake
                ASN1_primitive_new(ASN1_VALUE_st**, ASN1_ITEM_st const*)
                  at Sources/CNIOBoringSSL/crypto/asn1/tasn_new.cc:294
                  in /code/.build/aarch64-unknown-linux-gnu/release/simple-handshake
                static simple_handshake.SimpleHandshake.main() throws -> ()
                  at /code/Sources/simple-handshake/SimpleHandshake.swift:43
                  in /code/.build/aarch64-unknown-linux-gnu/release/simple-handshake
                static simple_handshake.SimpleHandshake.$main() throws -> ()
                  at //<compiler-generated>:40
                simple_handshake_main
                  at /code/Sources/simple-handshake/SimpleHandshake.swift:0
                0xffff935b73fa
                  in /lib/aarch64-linux-gnu/libc.so.6
                __libc_start_main
                  in /lib/aarch64-linux-gnu/libc.so.6


            total runtime: 0.44s.
            calls to allocation functions: 638104 (1440415/s)
            temporary memory allocations: 56039 (126498/s)
            peak heap memory consumption: 190.22K
            peak RSS (including heaptrack overhead): 21.92M
            total memory leaked: 5.54K
            """

        let lines = input.split(separator: "\n").map { String($0) }
        let stacks = HeaptrackParser.parse(lines: lines)

        try #require(stacks.count == 2)

        let stack0 = stacks[0]
        let expected0 = WeightedStack(
            lines: [
                "CNIOBoringSSL_OPENSSL_zalloc",
                "CNIOBoringSSL_ASN1_item_ex_new",
                "ASN1_template_new(ASN1_VALUE_st**, ASN1_TEMPLATE_st const*)",
                "CNIOBoringSSL_ASN1_item_ex_new",
                "asn1_item_ex_d2i(ASN1_VALUE_st**, unsigned char const**, long, ASN1_ITEM_st const*, int, int, char, crypto_buffer_st*, int)",
                "static simple_handshake.SimpleHandshake.$main() throws -> ()",
                "simple_handshake_main",
                "__libc_start_main",
            ],
            allocations: 3000
        )
        #expect(stack0 == expected0)

        let stack1 = stacks[1]
        let expected1 = WeightedStack(
            lines: [
                "CNIOBoringSSL_ASN1_STRING_type_new",
                "ASN1_primitive_new(ASN1_VALUE_st**, ASN1_ITEM_st const*)",
                "static simple_handshake.SimpleHandshake.main() throws -> ()",
                "static simple_handshake.SimpleHandshake.$main() throws -> ()",
                "simple_handshake_main",
                "__libc_start_main",
            ],
            allocations: 2000
        )
        #expect(stack1 == expected1)
    }
}
