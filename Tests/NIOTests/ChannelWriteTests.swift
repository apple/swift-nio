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
@testable import NIO

class ChannelWriteTests: XCTestCase {
    func testWriteVIsTailRecursiveAndLoopifiedInReleaseMode() throws {
        if !_isDebugAssertConfiguration() {
            let numberOfWritesToSmashTheStackIfNotTurnedIntoALoop = 500_000
            let allocator = ByteBufferAllocator()
            let d = "X".data(using: .utf8)!
            let head: PendingWrite? = PendingWrite(buffer: ByteBuffer(allocator: allocator, data: d, offset: 0, length: 1, maxCapacity: 1),
                                                   promise: Promise())
            var tail: PendingWrite? = head
            for _ in 0..<numberOfWritesToSmashTheStackIfNotTurnedIntoALoop {
                let new = PendingWrite(buffer: ByteBuffer(allocator: allocator, data: d, offset: 0, length: 1, maxCapacity: 1),
                                       promise: Promise())
                tail!.next = new
                tail = new
            }
            _ = doPendingWriteVectorOperation(pending: head, count: numberOfWritesToSmashTheStackIfNotTurnedIntoALoop+1) { iovecs in
                XCTAssertEqual(numberOfWritesToSmashTheStackIfNotTurnedIntoALoop+1, iovecs.count)
                for i in 0..<iovecs.count {
                    if d.first! != iovecs[i].iov_base.assumingMemoryBound(to: UInt8.self).pointee {
                        break
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
