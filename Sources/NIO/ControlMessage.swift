//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import CNIODarwin
#elseif os(Linux) || os(FreeBSD) || os(Android)
import CNIOLinux
#endif

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
        
        static func < (lhs: UnsafeControlMessageCollection.Index,
                       rhs: UnsafeControlMessageCollection.Index) -> Bool {
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
            let firstCMsg = Posix.cmsgFirstHeader(inside: messageHeaderPtr)
            return Index(cmsgPointer: firstCMsg)
        }
    }
    
    var endIndex: Index { return Index(cmsgPointer: nil) }
    
    func index(after: Index) -> Index {
        var msgHdr = messageHeader
        return withUnsafeMutablePointer(to: &msgHdr) { messageHeaderPtr in
            return Index(cmsgPointer: Posix.cmsgNextHeader(inside: messageHeaderPtr,
                                                           after: after.cmsgPointer!))
        }
    }
    
    public subscript(position: Index) -> Element {
        let cmsg = position.cmsgPointer!
        return UnsafeControlMessage(level: cmsg.pointee.cmsg_level,
                                    type: cmsg.pointee.cmsg_type,
                                    data: Posix.cmsgData(for: cmsg))
    }
}

/// Extract information from a collection of control messages.
struct ControlMessageParser {
    var ecnValue: NIOExplicitCongestionNotificationState = .transportNotCapable // Default

    init(parsing controlMessagesReceived: UnsafeControlMessageCollection) {
        for controlMessage in controlMessagesReceived {
            self.receiveMessage(controlMessage)
        }
    }
    
    #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
    private static let ipv4TosType = IP_RECVTOS
    #else
    private static let ipv4TosType = IP_TOS    // Linux
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
    
    mutating func receiveMessage(_ controlMessage: UnsafeControlMessage) {
        if controlMessage.level == IPPROTO_IP && controlMessage.type == ControlMessageParser.ipv4TosType {
            if let data = controlMessage.data {
                assert(data.count == 1)
                precondition(data.count >= 1)
                let readValue = CInt(data[0])
                self.ecnValue = .init(receivedValue: readValue)
            }
        } else if controlMessage.level == IPPROTO_IPV6 && controlMessage.type == IPV6_TCLASS {
            if let data = controlMessage.data {
                let readValue = ControlMessageParser._readCInt(data: data)
                self.ecnValue = .init(receivedValue: readValue)
            }
        }
    }
}

extension NIOExplicitCongestionNotificationState {
    /// Initialise a NIOExplicitCongestionNotificationState from a value received via either TCLASS or TOS cmsg.
    init(receivedValue: CInt) {
        switch receivedValue & IPTOS_ECN_MASK {
        case IPTOS_ECN_ECT1:
            self = .transportCapableFlag1
        case IPTOS_ECN_ECT0:
            self = .transportCapableFlag0
        case IPTOS_ECN_CE:
            self = .congestionExperienced
        default:
            self = .transportNotCapable
        }
    }
}

extension CInt {
    #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
    private static let notCapableValue = IPTOS_ECN_NOTECT
    #else
    private static let notCapableValue = IPTOS_ECN_NOT_ECT    // Linux
    #endif

    /// Create a CInt encoding of ExplicitCongestionNotification suitable for sending in TCLASS or TOS cmsg.
    init(ecnValue: NIOExplicitCongestionNotificationState) {
        switch ecnValue {
        case .transportNotCapable:
            self = CInt.notCapableValue
        case .transportCapableFlag0:
            self = IPTOS_ECN_ECT0
        case .transportCapableFlag1:
            self = IPTOS_ECN_ECT1
        case .congestionExperienced:
            self = IPTOS_ECN_CE
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
    private mutating func appendGenericControlMessage<PayloadType>(level: CInt,
                                                                   type: CInt,
                                                                   payload: PayloadType) {
        let writableBuffer = UnsafeMutableRawBufferPointer(rebasing: self.controlBytes[writePosition...])
        
        let requiredSize = Posix.cmsgSpace(payloadSize: MemoryLayout.stride(ofValue: payload))
        precondition(writableBuffer.count >= requiredSize, "Insufficient size for cmsghdr and data")
        
        let bufferBase = writableBuffer.baseAddress!
        // Binding to cmsghdr is safe here as this is the only place where we bind to non-Raw.
        let cmsghdrPtr = bufferBase.bindMemory(to: cmsghdr.self, capacity: 1)
        cmsghdrPtr.pointee.cmsg_level = level
        cmsghdrPtr.pointee.cmsg_type = type
        cmsghdrPtr.pointee.cmsg_len = .init(Posix.cmsgLen(payloadSize: MemoryLayout.size(ofValue: payload)))
        
        let dataPointer = Posix.cmsgData(for: cmsghdrPtr)!
        precondition(dataPointer.count >= MemoryLayout<PayloadType>.stride)
        dataPointer.storeBytes(of: payload, as: PayloadType.self)
        
        self.writePosition += requiredSize
    }
    
    /// The result is only valid while this is valid.
    var validControlBytes: UnsafeMutableRawBufferPointer {
        if writePosition == 0 {
            return UnsafeMutableRawBufferPointer(start: nil, count: 0)
        }
        return UnsafeMutableRawBufferPointer(rebasing: self.controlBytes[0 ..< self.writePosition])
    }
    
}

extension UnsafeOutboundControlBytes {
    /// Add a message describing the explicit congestion state if requested in metadata and valid for this protocol.
    ///  Parameters:
    ///     - metadata:   Metadata from the addressed envelope which will describe any desired state.
    ///     - protocolFamily:  The type of protocol to encode for.
    internal mutating func appendExplicitCongestionState(metadata: AddressedEnvelope<ByteBuffer>.Metadata?,
                                                         protocolFamily: NIOBSDSocket.ProtocolFamily?) {
        guard let metadata = metadata else { return }

        switch protocolFamily {
        case .some(.inet):
            self.appendControlMessage(level: .init(IPPROTO_IP),
                                      type: IP_TOS,
                                      payload: CInt(ecnValue: metadata.ecnState))
        case .some(.inet6):
            self.appendControlMessage(level: .init(IPPROTO_IPV6),
                                      type: IPV6_TCLASS,
                                      payload: CInt(ecnValue: metadata.ecnState))
        default:
            // Nothing to do - if we get here the user is probably making a mistake.
            break
        }
    }
}

extension AddressedEnvelope.Metadata {
    /// It's assumed the caller has checked that congestion information is required before calling.
    internal init(from controlMessagesReceived: UnsafeControlMessageCollection) {
        let controlMessageReceiver = ControlMessageParser(parsing: controlMessagesReceived)
        self.init(ecnState: controlMessageReceiver.ecnValue)
    }
}
