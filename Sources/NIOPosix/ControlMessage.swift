//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIOCore

#if canImport(Darwin)
import CNIODarwin
#elseif os(Linux) || os(FreeBSD) || os(Android)
import CNIOLinux
#elseif os(OpenBSD)
import CNIOOpenBSD
import Glibc
#elseif os(Windows)
import CNIOWindows
#endif

#if os(Windows)
private let _IPPROTO_IP = WinSDK.IPPROTO_IPV4.rawValue
private let _IPPROTO_IPV6 = WinSDK.IPPROTO_IPV6.rawValue
#else
private let _IPPROTO_IP = IPPROTO_IP
private let _IPPROTO_IPV6 = IPPROTO_IPV6
#endif

/// Memory for use as `cmsghdr` and associated data.
/// Supports multiple messages each with enough storage for multiple `cmsghdr`
struct UnsafeControlMessageStorage: Collection {
    let bytesPerMessage: Int
    var buffer: UnsafeMutableRawBufferPointer
    private let deallocateBuffer: Bool

    /// Initialise which includes allocating memory
    /// - Parameters:
    ///   - bytesPerMessage: How many bytes have been allocated for each supported message.
    ///   - buffer: The memory allocated to use for control messages.
    ///   - deallocateBuffer: buffer owning indicator
    private init(bytesPerMessage: Int, buffer: UnsafeMutableRawBufferPointer, deallocateBuffer: Bool) {
        self.bytesPerMessage = bytesPerMessage
        self.buffer = buffer
        self.deallocateBuffer = deallocateBuffer
    }

    // Guess that 4 Int32 payload messages is enough for anyone.
    static var bytesPerMessage: Int { NIOBSDSocketControlMessage.space(payloadSize: MemoryLayout<Int32>.stride) * 4 }

    /// Allocate new memory - Caller must call `deallocate` when no longer required.
    /// - Parameters:
    ///   - msghdrCount: How many `msghdr` structures will be fed from this buffer - we assume 4 Int32 cmsgs for each.
    static func allocate(msghdrCount: Int) -> UnsafeControlMessageStorage {
        let bytesPerMessage = Self.bytesPerMessage
        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: bytesPerMessage * msghdrCount,
            alignment: MemoryLayout<cmsghdr>.alignment
        )
        return UnsafeControlMessageStorage(bytesPerMessage: bytesPerMessage, buffer: buffer, deallocateBuffer: true)
    }

    /// Create an instance not owning the buffer
    /// - Parameters:
    ///   - bytesPerMessage: How many bytes have been allocated for each supported message.
    ///   - buffer: The memory allocated to use for control messages.
    static func makeNotOwning(
        bytesPerMessage: Int,
        buffer: UnsafeMutableRawBufferPointer
    ) -> UnsafeControlMessageStorage {
        precondition(buffer.count >= bytesPerMessage)
        return UnsafeControlMessageStorage(bytesPerMessage: bytesPerMessage, buffer: buffer, deallocateBuffer: false)
    }

    mutating func deallocate() {
        if self.deallocateBuffer {
            self.buffer.deallocate()
            self.buffer = UnsafeMutableRawBufferPointer(
                start: UnsafeMutableRawPointer(bitPattern: 0x7ead_beef),
                count: 0
            )
        }
    }

    /// Get the part of the buffer for use with a message.
    public subscript(position: Int) -> UnsafeMutableRawBufferPointer {
        UnsafeMutableRawBufferPointer(
            rebasing: self.buffer[
                (position * self.bytesPerMessage)..<((position + 1) * self.bytesPerMessage)
            ]
        )
    }

    var startIndex: Int { 0 }

    var endIndex: Int { self.buffer.count / self.bytesPerMessage }

    func index(after: Int) -> Int {
        after + 1
    }
}

/// Representation of a `cmsghdr` and associated data.
/// Unsafe as captures pointers and must not escape the scope where those pointers are valid.
struct UnsafeControlMessage {
    var level: CInt
    var type: CInt
    var data: UnsafeRawBufferPointer?
}

/// Collection representation of `cmsghdr` structures and associated data from `recvmsg`
/// Unsafe as captures pointers held in msghdr structure which must not escape scope of validity.
struct UnsafeControlMessageCollection {
    private var messageHeader: msghdr

    init(messageHeader: msghdr) {
        self.messageHeader = messageHeader
    }
}

// Add the `Collection` functionality to UnsafeControlMessageCollection.
extension UnsafeControlMessageCollection: Collection {
    typealias Element = UnsafeControlMessage

    struct Index: Equatable, Comparable {
        fileprivate var cmsgPointer: UnsafeMutablePointer<cmsghdr>?

        static func < (
            lhs: UnsafeControlMessageCollection.Index,
            rhs: UnsafeControlMessageCollection.Index
        ) -> Bool {
            // nil is high, as that's the end of the collection.
            switch (lhs.cmsgPointer, rhs.cmsgPointer) {
            case (.some(let lhs), .some(let rhs)):
                return lhs < rhs
            case (.some, .none):
                return true
            case (.none, .some), (.none, .none):
                return false
            }
        }

        fileprivate init(cmsgPointer: UnsafeMutablePointer<cmsghdr>?) {
            self.cmsgPointer = cmsgPointer
        }
    }

    var startIndex: Index {
        var messageHeader = self.messageHeader
        return withUnsafePointer(to: &messageHeader) { messageHeaderPtr in
            let firstCMsg = NIOBSDSocketControlMessage.firstHeader(inside: messageHeaderPtr)
            return Index(cmsgPointer: firstCMsg)
        }
    }

    var endIndex: Index { Index(cmsgPointer: nil) }

    func index(after: Index) -> Index {
        var msgHdr = messageHeader
        return withUnsafeMutablePointer(to: &msgHdr) { messageHeaderPtr in
            Index(
                cmsgPointer: NIOBSDSocketControlMessage.nextHeader(
                    inside: messageHeaderPtr,
                    after: after.cmsgPointer!
                )
            )
        }
    }

    public subscript(position: Index) -> Element {
        let cmsg = position.cmsgPointer!
        return UnsafeControlMessage(
            level: cmsg.pointee.cmsg_level,
            type: cmsg.pointee.cmsg_type,
            data: NIOBSDSocketControlMessage.data(for: cmsg)
        )
    }
}

/// Small struct to link a buffer used for control bytes and the processing of those bytes.
struct UnsafeReceivedControlBytes {
    var controlBytesBuffer: UnsafeMutableRawBufferPointer
    /// Set when a message is received which is using the controlBytesBuffer - the lifetime will be tied to that of `controlBytesBuffer`
    var receivedControlMessages: UnsafeControlMessageCollection?

    init(controlBytesBuffer: UnsafeMutableRawBufferPointer) {
        self.controlBytesBuffer = controlBytesBuffer
    }
}

/// Extract information from a collection of control messages.
struct ControlMessageParser {
    var ecnValue: NIOExplicitCongestionNotificationState = .transportNotCapable  // Default
    var packetInfo: NIOPacketInfo? = nil
    var segmentSize: Int? = nil

    init(parsing controlMessagesReceived: UnsafeControlMessageCollection) {
        for controlMessage in controlMessagesReceived {
            self.receiveMessage(controlMessage)
        }
    }

    #if canImport(Darwin)
    private static let ipv4TosType = IP_RECVTOS
    #else
    private static let ipv4TosType = IP_TOS  // Linux
    #endif

    static func _readCInt(data: UnsafeRawBufferPointer) -> CInt {
        assert(data.count == MemoryLayout<CInt>.size)
        precondition(data.count >= MemoryLayout<CInt>.size)
        var readValue = CInt(0)
        withUnsafeMutableBytes(of: &readValue) { valuePtr in
            valuePtr.copyMemory(from: data)
        }
        return readValue
    }

    private mutating func receiveMessage(_ controlMessage: UnsafeControlMessage) {
        if controlMessage.level == _IPPROTO_IP {
            self.receiveIPv4Message(controlMessage)
        } else if controlMessage.level == _IPPROTO_IPV6 {
            self.receiveIPv6Message(controlMessage)
        } else if controlMessage.level == Posix.SOL_UDP {
            self.receiveUDPMessage(controlMessage)
        }
    }

    private mutating func receiveIPv4Message(_ controlMessage: UnsafeControlMessage) {
        if controlMessage.type == ControlMessageParser.ipv4TosType {
            if let data = controlMessage.data {
                assert(data.count == 1)
                precondition(data.count >= 1)
                let readValue = CInt(data[0])
                self.ecnValue = .init(receivedValue: readValue)
            }
        } else if controlMessage.type == Posix.IP_PKTINFO {
            #if !os(OpenBSD)
            if let data = controlMessage.data {
                let info = data.load(as: in_pktinfo.self)
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(NIOBSDSocket.AddressFamily.inet.rawValue)
                addr.sin_port = in_port_t(0)
                addr.sin_addr = info.ipi_addr
                self.packetInfo = NIOPacketInfo(
                    destinationAddress: SocketAddress(addr, host: ""),
                    interfaceIndex: Int(info.ipi_ifindex)
                )
            }
            #endif
        }
    }

    private mutating func receiveIPv6Message(_ controlMessage: UnsafeControlMessage) {
        if controlMessage.type == IPV6_TCLASS {
            if let data = controlMessage.data {
                let readValue = ControlMessageParser._readCInt(data: data)
                self.ecnValue = .init(receivedValue: readValue)
            }
        } else if controlMessage.type == Posix.IPV6_PKTINFO {
            if let data = controlMessage.data {
                let info = data.load(as: in6_pktinfo.self)
                var addr = sockaddr_in6()
                addr.sin6_family = sa_family_t(NIOBSDSocket.AddressFamily.inet6.rawValue)
                addr.sin6_port = in_port_t(0)
                addr.sin6_flowinfo = 0
                addr.sin6_addr = info.ipi6_addr
                addr.sin6_scope_id = 0
                self.packetInfo = NIOPacketInfo(
                    destinationAddress: SocketAddress(addr, host: ""),
                    interfaceIndex: Int(info.ipi6_ifindex)
                )
            }
        }
    }

    private mutating func receiveUDPMessage(_ controlMessage: UnsafeControlMessage) {
        #if os(Linux)
        if controlMessage.type == .init(NIOBSDSocket.Option.udp_gro.rawValue) {
            if let data = controlMessage.data {
                let readValue = ControlMessageParser._readCInt(data: data)
                self.segmentSize = Int(readValue)
            }
        }
        #endif
    }
}

extension NIOExplicitCongestionNotificationState {
    /// Initialise a NIOExplicitCongestionNotificationState from a value received via either TCLASS or TOS cmsg.
    init(receivedValue: CInt) {
        switch receivedValue & Posix.IPTOS_ECN_MASK {
        case Posix.IPTOS_ECN_ECT1:
            self = .transportCapableFlag1
        case Posix.IPTOS_ECN_ECT0:
            self = .transportCapableFlag0
        case Posix.IPTOS_ECN_CE:
            self = .congestionExperienced
        default:
            self = .transportNotCapable
        }
    }
}

extension CInt {
    /// Create a CInt encoding of ExplicitCongestionNotification suitable for sending in TCLASS or TOS cmsg.
    init(ecnValue: NIOExplicitCongestionNotificationState) {
        switch ecnValue {
        case .transportNotCapable:
            self = Posix.IPTOS_ECN_NOTECT
        case .transportCapableFlag0:
            self = Posix.IPTOS_ECN_ECT0
        case .transportCapableFlag1:
            self = Posix.IPTOS_ECN_ECT1
        case .congestionExperienced:
            self = Posix.IPTOS_ECN_CE
        }
    }
}

struct UnsafeOutboundControlBytes {
    private var controlBytes: UnsafeMutableRawBufferPointer
    private var writePosition: UnsafeMutableRawBufferPointer.Index

    /// This structure must not outlive `controlBytes`
    init(controlBytes: UnsafeMutableRawBufferPointer) {
        self.controlBytes = controlBytes
        self.writePosition = controlBytes.startIndex
    }

    mutating func appendControlMessage(level: CInt, type: CInt, payload: CInt) {
        self.appendGenericControlMessage(level: level, type: type, payload: payload)
    }

    /// Appends a control message.
    /// PayloadType needs to be trivial (eg CInt)
    private mutating func appendGenericControlMessage<PayloadType>(
        level: CInt,
        type: CInt,
        payload: PayloadType
    ) {
        let writableBuffer = UnsafeMutableRawBufferPointer(
            rebasing: self.controlBytes[writePosition...]
        )

        let requiredSize = NIOBSDSocketControlMessage.space(payloadSize: MemoryLayout.stride(ofValue: payload))
        precondition(writableBuffer.count >= requiredSize, "Insufficient size for cmsghdr and data")

        let bufferBase = writableBuffer.baseAddress!
        // Binding to cmsghdr is safe here as this is the only place where we bind to non-Raw.
        let cmsghdrPtr = bufferBase.bindMemory(to: cmsghdr.self, capacity: 1)
        cmsghdrPtr.pointee.cmsg_level = level
        cmsghdrPtr.pointee.cmsg_type = type
        cmsghdrPtr.pointee.cmsg_len = .init(
            NIOBSDSocketControlMessage.length(payloadSize: MemoryLayout.size(ofValue: payload))
        )

        let dataPointer = NIOBSDSocketControlMessage.data(for: cmsghdrPtr)!
        precondition(dataPointer.count >= MemoryLayout<PayloadType>.stride)
        dataPointer.storeBytes(of: payload, as: PayloadType.self)

        self.writePosition += requiredSize
    }

    /// The result is only valid while this is valid.
    var validControlBytes: UnsafeMutableRawBufferPointer {
        if writePosition == 0 {
            return UnsafeMutableRawBufferPointer(start: nil, count: 0)
        }
        return UnsafeMutableRawBufferPointer(rebasing: self.controlBytes[0..<self.writePosition])
    }

}

extension UnsafeOutboundControlBytes {
    /// Add a message describing the explicit congestion state if requested in metadata and valid for this protocol.
    ///  Parameters:
    ///   - metadata:   Metadata from the addressed envelope which will describe any desired state.
    ///   - protocolFamily:  The type of protocol to encode for.
    internal mutating func appendExplicitCongestionState(
        metadata: AddressedEnvelope<ByteBuffer>.Metadata?,
        protocolFamily: NIOBSDSocket.ProtocolFamily?
    ) {
        guard let metadata = metadata else { return }

        switch protocolFamily {
        case .some(.inet):
            self.appendControlMessage(
                level: .init(IPPROTO_IP),
                type: IP_TOS,
                payload: CInt(ecnValue: metadata.ecnState)
            )
        case .some(.inet6):
            self.appendControlMessage(
                level: .init(_IPPROTO_IPV6),
                type: IPV6_TCLASS,
                payload: CInt(ecnValue: metadata.ecnState)
            )
        default:
            // Nothing to do - if we get here the user is probably making a mistake.
            break
        }
    }

    /// Appends a UDP segment size control message for Generic Segmentation Offload (GSO).
    ///
    /// - Parameter metadata: Metadata from the addressed envelope which may contain a segment size.
    /// - Warning: This will `fatalError` if called with a segmentSize on non-Linux platforms.
    ///   Callers should validate platform support before enqueueing writes with segmentSize.
    internal mutating func appendUDPSegmentSize(metadata: AddressedEnvelope<ByteBuffer>.Metadata?) {
        guard let metadata = metadata, let segmentSize = metadata.segmentSize else { return }

        #if os(Linux)
        self.appendGenericControlMessage(
            level: Posix.SOL_UDP,
            type: .init(NIOBSDSocket.Option.udp_segment.rawValue),
            payload: UInt16(segmentSize)
        )
        #else
        fatalError("UDP segment size is only supported on Linux")
        #endif
    }
}

extension AddressedEnvelope.Metadata {
    /// It's assumed the caller has checked that congestion information is required before calling.
    internal init(from controlMessagesReceived: UnsafeControlMessageCollection) {
        let controlMessageReceiver = ControlMessageParser(parsing: controlMessagesReceived)
        self.init(
            ecnState: controlMessageReceiver.ecnValue,
            packetInfo: controlMessageReceiver.packetInfo,
            segmentSize: controlMessageReceiver.segmentSize
        )
    }
}
