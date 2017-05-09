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
import Future

protocol ChannelOutboundInvoker {
    
    func write(data: Buffer) -> Future<Void>
    func write(data: Buffer, promise: Promise<Void>) -> Future<Void>

    func flush()
    func read()
    
    func writeAndFlush(data: Buffer) -> Future<Void>
    func writeAndFlush(data: Buffer, promise: Promise<Void>) -> Future<Void>

    func close() -> Future<Void>
    func close(promise: Promise<Void>) -> Future<Void>
}

// Default implementations for methods that not take a promise.
extension ChannelOutboundInvoker {
    public func write(data: Buffer) -> Future<Void> {
        return write(data: data, promise: Promise<Void>())
    }

    public func writeAndFlush(data: Buffer) -> Future<Void> {
        return writeAndFlush(data: data, promise: Promise<Void>())
    }
    
    public func close() -> Future<Void> {
        return close(promise: Promise<Void>())
    }
}
