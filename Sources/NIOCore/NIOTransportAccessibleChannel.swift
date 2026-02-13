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

/// A ``NIOTransportAccessibleChannel`` is a ``ChannelCore`` that provides access to its underlying transport.
public protocol NIOTransportAccessibleChannel<Transport>: ChannelCore {
    /// The type of the underlying transport.
    associatedtype Transport

    /// Provides scoped access to the underlying transport.
    ///
    /// This is an advanced API for reading or manipulating the underlying transport that backs a channel. Users must
    /// not close the transport or invalidate any invariants that NIO relies upon for the channel operation.
    ///
    /// Not all channels are expected to conform to ``NIOTransportAccessibleChannel``, but this can be determined at
    /// runtime.
    ///
    /// Users should not attempt to use this API direcly, but should instead use
    /// ``ChannelPipeline/SynchronousOperations/withUnsafeTransportIfAvailable(of:_:)``.
    ///
    /// - Parameter body: A closure that takes the underlying transport.
    /// - Returns: The value returned by the closure.
    /// - Throws: If the underlying transport is unavailable, or rethrows any error thrown by the closure.
    func withUnsafeTransport<Result>(_ body: (_ transport: Transport) throws -> Result) throws -> Result
}
