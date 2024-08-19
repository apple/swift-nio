//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

// 'any Error' is unconditionally boxed, avoid allocating per use by statically boxing them.
extension ChannelError {
    static let _alreadyClosed: any Error = ChannelError.alreadyClosed
    static let _badInterfaceAddressFamily: any Error = ChannelError.badInterfaceAddressFamily
    static let _badMulticastGroupAddressFamily: any Error = ChannelError.badMulticastGroupAddressFamily
    static let _connectPending: any Error = ChannelError.connectPending
    static let _eof: any Error = ChannelError.eof
    static let _inappropriateOperationForState: any Error = ChannelError.inappropriateOperationForState
    static let _inputClosed: any Error = ChannelError.inputClosed
    static let _ioOnClosedChannel: any Error = ChannelError.ioOnClosedChannel
    static let _operationUnsupported: any Error = ChannelError.operationUnsupported
    static let _outputClosed: any Error = ChannelError.outputClosed
    static let _unknownLocalAddress: any Error = ChannelError.unknownLocalAddress
    static let _writeHostUnreachable: any Error = ChannelError.writeHostUnreachable
    static let _writeMessageTooLarge: any Error = ChannelError.writeMessageTooLarge
}

extension EventLoopError {
    static let _shutdown: any Error = EventLoopError.shutdown
    static let _unsupportedOperation: any Error = EventLoopError.unsupportedOperation
}
