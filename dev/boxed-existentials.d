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
 *   sudo dev/boxed-existentials.d -c .build/release/NIOHTTP1Server
 */

pid$target::__swift_allocate_boxed_opaque_existential*:entry {
    ustack();
}
