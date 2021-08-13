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
import NIOCore

extension BaseSocketChannel: SocketOptionProvider {
    #if !os(Windows)
        func unsafeSetSocketOption<Value>(level: SocketOptionLevel, name: SocketOptionName, value: Value) -> EventLoopFuture<Void> {
            return unsafeSetSocketOption(level: NIOBSDSocket.OptionLevel(rawValue: CInt(level)), name: NIOBSDSocket.Option(rawValue: CInt(name)), value: value)
        }
    #endif

    func unsafeSetSocketOption<Value>(level: NIOBSDSocket.OptionLevel, name: NIOBSDSocket.Option, value: Value) -> EventLoopFuture<Void> {
        if eventLoop.inEventLoop {
            let promise = eventLoop.makePromise(of: Void.self)
            executeAndComplete(promise) {
                try setSocketOption0(level: level, name: name, value: value)
            }
            return promise.futureResult
        } else {
            return eventLoop.submit {
                try self.setSocketOption0(level: level, name: name, value: value)
            }
        }
    }

    #if !os(Windows)
        func unsafeGetSocketOption<Value>(level: SocketOptionLevel, name: SocketOptionName) -> EventLoopFuture<Value> {
            return unsafeGetSocketOption(level: NIOBSDSocket.OptionLevel(rawValue: CInt(level)), name: NIOBSDSocket.Option(rawValue: CInt(name)))
        }
    #endif

    func unsafeGetSocketOption<Value>(level: NIOBSDSocket.OptionLevel, name: NIOBSDSocket.Option) -> EventLoopFuture<Value> {
        if eventLoop.inEventLoop {
            let promise = eventLoop.makePromise(of: Value.self)
            executeAndComplete(promise) {
                try getSocketOption0(level: level, name: name)
            }
            return promise.futureResult
        } else {
            return eventLoop.submit {
                try self.getSocketOption0(level: level, name: name)
            }
        }
    }

    func setSocketOption0<Value>(level: NIOBSDSocket.OptionLevel, name: NIOBSDSocket.Option, value: Value) throws {
        try self.socket.setOption(level: level, name: name, value: value)
    }

    func getSocketOption0<Value>(level: NIOBSDSocket.OptionLevel, name: NIOBSDSocket.Option) throws -> Value {
        return try self.socket.getOption(level: level, name: name)
    }
}
