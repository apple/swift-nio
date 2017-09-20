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
import Foundation
import XCTest
import NIO
import Dispatch
import ConcurrencyHelpers

public class EventLoopTest : XCTestCase {
    
    public func testSchedule() throws {
        let nanos = DispatchTime.now().uptimeNanoseconds
        let amount: TimeAmount = .seconds(1)
        let eventLoopGroup = try MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! eventLoopGroup.syncShutdownGracefully()
        }
        let value = try eventLoopGroup.next().scheduleTask(in: amount) {
            return true
        }.futureResult.wait()
        
        XCTAssertTrue(DispatchTime.now().uptimeNanoseconds - nanos >= amount.nanoseconds)
        XCTAssertTrue(value)
    }
    
    public func testScheduleCancelled() throws {
        let eventLoopGroup = try MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! eventLoopGroup.syncShutdownGracefully()
        }
        let ran = Atomic<Bool>(value: false)
        let scheduled = eventLoopGroup.next().scheduleTask(in: .seconds(2)) {
            ran.store(true)
        }
        
        scheduled.cancel()
        
        let nanos = DispatchTime.now().uptimeNanoseconds
        let amount: TimeAmount = .seconds(2)
        let value = try eventLoopGroup.next().scheduleTask(in: amount) {
            return true
        }.futureResult.wait()
        
        XCTAssertTrue(DispatchTime.now().uptimeNanoseconds - nanos >= amount.nanoseconds)
        XCTAssertTrue(value)
        XCTAssertFalse(ran.load())
    }
}
