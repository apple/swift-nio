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
// IntegerBitPackingTests+XCTest.swift
//
import XCTest

///
/// NOTE: This file was generated by generate_linux_tests.rb
///
/// Do NOT edit this file directly as it will be regenerated automatically when needed.
///

extension IntegerBitPackingTests {

   @available(*, deprecated, message: "not actually deprecated. Just deprecated to allow deprecated tests (which test deprecated functionality) without warnings")
   static var allTests : [(String, (IntegerBitPackingTests) -> () throws -> Void)] {
      return [
                ("testAllUInt8PairsRoundtrip", testAllUInt8PairsRoundtrip),
                ("testExtremesWorkForUInt32UInt16UInt8", testExtremesWorkForUInt32UInt16UInt8),
                ("testExtremesWorkForUInt16UInt8", testExtremesWorkForUInt16UInt8),
                ("testExtremesWorkForUInt32CInt", testExtremesWorkForUInt32CInt),
           ]
   }
}

