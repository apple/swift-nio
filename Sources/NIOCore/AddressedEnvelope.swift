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
    /// Any metadata associated with this `AddressedEnvelope`
    public var metadata: Metadata? = nil

    public init(remoteAddress: SocketAddress, data: DataType) {
        self.remoteAddress = remoteAddress
        self.data = data
    }

    public init(remoteAddress: SocketAddress, data: DataType, metadata: Metadata?) {
        self.remoteAddress = remoteAddress
        self.data = data
        self.metadata = metadata
    }

    /// Any metadata associated with an `AddressedEnvelope`
    public struct Metadata: Hashable, Sendable {
        /// Details of any congestion state.
        public var ecnState: NIOExplicitCongestionNotificationState
        public var packetInfo: NIOPacketInfo?
        /// The UDP segment size for Generic Segmentation Offload (GSO).
        ///
        /// When set, this enables per-message GSO, allowing the kernel to split this datagram
        /// into multiple segments of the specified size. The maximum segment size is platform-dependent
        /// and can be queried via `System.udpMaxSegments`.
        ///
        /// On non-Linux platforms, writes with a non-nil `segmentSize` will fail with
        /// `ChannelError.operationUnsupported`. The error will be propagated to the write promise
        /// (if attached).
        public var segmentSize: Int?

        public init(ecnState: NIOExplicitCongestionNotificationState) {
            self.ecnState = ecnState
            self.packetInfo = nil
            self.segmentSize = nil
        }

        public init(ecnState: NIOExplicitCongestionNotificationState, packetInfo: NIOPacketInfo?) {
            self.ecnState = ecnState
            self.packetInfo = packetInfo
            self.segmentSize = nil
        }

        public init(
            ecnState: NIOExplicitCongestionNotificationState,
            packetInfo: NIOPacketInfo?,
            segmentSize: Int?
        ) {
            self.ecnState = ecnState
            self.packetInfo = packetInfo
            self.segmentSize = segmentSize
        }
    }
}

extension AddressedEnvelope: CustomStringConvertible {
    public var description: String {
        "AddressedEnvelope { remoteAddress: \(self.remoteAddress), data: \(self.data) }"
    }
}

extension AddressedEnvelope: Equatable where DataType: Equatable {}

extension AddressedEnvelope: Hashable where DataType: Hashable {}

extension AddressedEnvelope: Sendable where DataType: Sendable {}

/// Possible Explicit Congestion Notification States
public enum NIOExplicitCongestionNotificationState: Hashable, Sendable {
    /// Non-ECN Capable Transport.
    case transportNotCapable
    /// ECN Capable Transport (flag 0).
    case transportCapableFlag0
    /// ECN Capable Transport (flag 1).
    case transportCapableFlag1
    /// Congestion Experienced.
    case congestionExperienced
}

public struct NIOPacketInfo: Hashable, Sendable {
    public var destinationAddress: SocketAddress
    public var interfaceIndex: Int

    public init(destinationAddress: SocketAddress, interfaceIndex: Int) {
        self.destinationAddress = destinationAddress
        self.interfaceIndex = interfaceIndex
    }
}
