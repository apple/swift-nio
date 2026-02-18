//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

extension BaseSocketChannel where SocketType: BaseSocket {
    /// The underlying transport type backing this channel.
    typealias Transport = NIOBSDSocket.Handle

    /// Provides scoped access to the socket file handle.
    func withUnsafeTransport<Result>(_ body: (_ transport: NIOBSDSocket.Handle) throws -> Result) throws -> Result {
        try self.socket.withUnsafeHandle(body)
    }
}

extension BaseSocketChannel where SocketType: PipePair {
    /// The underlying transport type backing this channel.
    typealias Transport = NIOBSDSocket.PipeHandle

    /// Provides scoped access to the pipe file descriptors.
    func withUnsafeTransport<Result>(_ body: (_ transport: NIOBSDSocket.PipeHandle) throws -> Result) throws -> Result {
        try body(
            NIOBSDSocket.PipeHandle(
                input: self.socket.input?.fileDescriptor ?? NIOBSDSocket.invalidHandle,
                output: self.socket.output?.fileDescriptor ?? NIOBSDSocket.invalidHandle
            )
        )
    }
}

extension SocketChannel: NIOTransportAccessibleChannelCore {}
extension ServerSocketChannel: NIOTransportAccessibleChannelCore {}
extension DatagramChannel: NIOTransportAccessibleChannelCore {}
extension PipeChannel: NIOTransportAccessibleChannelCore {}
