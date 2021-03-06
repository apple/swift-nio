//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
//
// EchoServerClientTest+XCTest.swift
//
import XCTest

///
/// NOTE: This file was generated by generate_linux_tests.rb
///
/// Do NOT edit this file directly as it will be regenerated automatically when needed.
///

extension EchoServerClientTest {

   @available(*, deprecated, message: "not actually deprecated. Just deprecated to allow deprecated tests (which test deprecated functionality) without warnings")
   static var allTests : [(String, (EchoServerClientTest) -> () throws -> Void)] {
      return [
                ("testEcho", testEcho),
                ("testLotsOfUnflushedWrites", testLotsOfUnflushedWrites),
                ("testEchoUnixDomainSocket", testEchoUnixDomainSocket),
                ("testConnectUnixDomainSocket", testConnectUnixDomainSocket),
                ("testCleanupUnixDomainSocket", testCleanupUnixDomainSocket),
                ("testBootstrapUnixDomainSocketNameClash", testBootstrapUnixDomainSocketNameClash),
                ("testChannelActiveOnConnect", testChannelActiveOnConnect),
                ("testWriteThenRead", testWriteThenRead),
                ("testCloseInInactive", testCloseInInactive),
                ("testFlushOnEmpty", testFlushOnEmpty),
                ("testWriteOnConnect", testWriteOnConnect),
                ("testWriteOnAccept", testWriteOnAccept),
                ("testWriteAfterChannelIsDead", testWriteAfterChannelIsDead),
                ("testPendingReadProcessedAfterWriteError", testPendingReadProcessedAfterWriteError),
                ("testChannelErrorEOFNotFiredThroughPipeline", testChannelErrorEOFNotFiredThroughPipeline),
                ("testPortNumbers", testPortNumbers),
                ("testConnectingToIPv4And6ButServerOnlyWaitsOnIPv4", testConnectingToIPv4And6ButServerOnlyWaitsOnIPv4),
           ]
   }
}

