//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
//  swift-nio
//
//  Created by Johannes Weiß on 06/06/2017.
//
//

import Foundation
import XCTest
import Future
import Sockets
@testable import NIO

class ChannelWriteTests: XCTestCase {
    func testWriteVIsTailRecursiveAndLoopifiedInReleaseMode() throws {
        if !_isDebugAssertConfiguration() {
            let numberOfWritesToSmashTheStackIfNotTurnedIntoALoop = 500_000
            let allocator = ByteBufferAllocator()
            let d = "Hello".data(using: .utf8)!
            let head: PendingWrite? = PendingWrite(buffer: ByteBuffer(allocator: allocator, data: d, offset: 0, length: 5, maxCapacity: 5),
                                                   promise: Promise())
            var tail: PendingWrite? = head
            for i in 0..<(numberOfWritesToSmashTheStackIfNotTurnedIntoALoop) {
                let len = (i % 5)+1
                let new = PendingWrite(buffer: ByteBuffer(allocator: allocator, data: d, offset: 0, length: len, maxCapacity: 2*len),
                                       promise: Promise())
                tail!.next = new
                tail = new
            }

            /* add a bogus one to check that the limit we pass in `count` later is respected. */
            tail!.next = PendingWrite(buffer: ByteBuffer(allocator: allocator, data: "BOGUS".data(using: .utf8)!, offset: 0, length: 5, maxCapacity: 5),
                                      promise: Promise())
            var iovecs_count = numberOfWritesToSmashTheStackIfNotTurnedIntoALoop + 1 /* doesn't include the bogus one */
            var iovecs: UnsafeMutablePointer<IOVector> = UnsafeMutablePointer.allocate(capacity: iovecs_count)
            defer {
                iovecs.deallocate(capacity: iovecs_count)
            }
            
            _ = doPendingWriteVectorOperation(pending: head, count: numberOfWritesToSmashTheStackIfNotTurnedIntoALoop+1, iovecs: UnsafeMutableBufferPointer(start: iovecs, count: iovecs_count)) { iovecs in
                XCTAssertEqual(numberOfWritesToSmashTheStackIfNotTurnedIntoALoop + 1, iovecs.count)
                for i in 0..<iovecs.count {
                    if i == 0 {
                        XCTAssertEqual(5, iovecs[i].iov_len)
                    } else {
                        let expectedLen = ((i-1) % 5)+1
                        XCTAssertEqual(expectedLen, iovecs[i].iov_len)
                        XCTAssertEqual(0, memcmp("Hello", iovecs[i].iov_base.assumingMemoryBound(to: UInt8.self), expectedLen))
                        if d.first! != iovecs[i].iov_base.assumingMemoryBound(to: UInt8.self).pointee {
                            break
                        }
                    }
                }
                return 0
            }
            if let head = head {
                head.promise.succeed(result: ())
                var next = head as PendingWrite?
                while let n = next {
                    n.promise.succeed(result: ())
                    next = n.next
                }
            }
        }
    }
}
