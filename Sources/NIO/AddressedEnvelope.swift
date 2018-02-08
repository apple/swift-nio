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

/// A data structure for processing addressed datagrams, such as those used by UDP.
///
/// The AddressedEnvelope is used extensively on `DatagramChannel`s in order to keep track
/// of source or destination address metadata: that is, where some data came from or where
/// it is going.
public struct AddressedEnvelope<DataType> {
    public var remoteAddress: SocketAddress
    public var data: DataType

    public init(remoteAddress: SocketAddress, data: DataType) {
        self.remoteAddress = remoteAddress
        self.data = data
    }
}
