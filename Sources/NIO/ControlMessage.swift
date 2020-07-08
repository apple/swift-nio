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
    var level: Int32
    var type: Int32
    var data: UnsafeRawBufferPointer?
}

/// Collection representation of `cmsghdr` structures and associated data from `recvmsg`
/// Unsafe as captures pointers held in msghdr structure which must not escape scope of validity.
struct UnsafeControlMessageCollection: Collection {
    typealias Index = ControlMessageIndex
    typealias Element = UnsafeControlMessage
    
    struct ControlMessageIndex: Equatable, Comparable {
        fileprivate var cmsgPointer: UnsafeMutablePointer<cmsghdr>?
        
        static func < (lhs: UnsafeControlMessageCollection.ControlMessageIndex,
                       rhs: UnsafeControlMessageCollection.ControlMessageIndex) -> Bool {
            // Nil must be high as it represents the end of the collection.
            if let lhsPointer = lhs.cmsgPointer {
                if let rhsPointer = rhs.cmsgPointer {
                    return lhsPointer < rhsPointer
                }
                return true
            }
            return false
        }
        
        fileprivate init(cmsgPointer: UnsafeMutablePointer<cmsghdr>?) {
            self.cmsgPointer = cmsgPointer
        }
    }
    
    var startIndex: Index {
        var messageHeader = self.messageHeader
        return withUnsafePointer(to: &messageHeader) { messageHeaderPtr in
            let firstCMsg = Posix.cmsgFirstHeader(inside: messageHeaderPtr)
            return ControlMessageIndex(cmsgPointer: firstCMsg)
        }
    }
    
    let endIndex = ControlMessageIndex(cmsgPointer: nil)
    
    func index(after: Index) -> Index {
        var msgHdr = messageHeader
        return withUnsafeMutablePointer(to: &msgHdr) { messageHeaderPtr in
            return ControlMessageIndex(cmsgPointer: Posix.cmsgNextHeader(inside: messageHeaderPtr,
                                                                         from: after.cmsgPointer))
        }
    }
    
    public subscript(position: Index) -> Element {
        let cmsg = position.cmsgPointer!
        return UnsafeControlMessage(level: cmsg.pointee.cmsg_level,
                                    type: cmsg.pointee.cmsg_type,
                                    data: Posix.cmsgData(for: cmsg))
    }
        
    private var messageHeader: msghdr
    
    init(messageHeader: msghdr) {
        self.messageHeader = messageHeader
    }
}

/// Extract information from a collection of control messages.
struct ControlMessageReceiver {
    var ecnValue: NIOExplicitCongestionNotificationState = .transportNotCapable // Default
    
    #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
    private static let ipv4TosType = IP_RECVTOS
    #else
    private static let ipv4TosType = IP_TOS    // Linux
    #endif
    
    mutating func receiveMessage(_ controlMessage: UnsafeControlMessage) {
        if controlMessage.level == IPPROTO_IP && controlMessage.type == ControlMessageReceiver.ipv4TosType {
            if let data = controlMessage.data {
                assert(data.count == 1)
                precondition(data.count >= 1)
                let readValue: Int32 = .init(data[0])
                self.ecnValue = ControlMessageReceiver.parseEcn(receivedValue: readValue)
            }
        } else if controlMessage.level == IPPROTO_IPV6 && controlMessage.type == IPV6_TCLASS {
            if let data = controlMessage.data {
                assert(data.count == 4)
                precondition(data.count >= 4)
                var readValue: Int32 = 0
                withUnsafeMutableBytes(of: &readValue) { valuePtr in
                    valuePtr.copyMemory(from: data)
                }
                self.ecnValue = ControlMessageReceiver.parseEcn(receivedValue: readValue)
            }
        }
    }

    private static func parseEcn(receivedValue: Int32) -> NIOExplicitCongestionNotificationState {
        switch receivedValue & IPTOS_ECN_MASK {
        case IPTOS_ECN_ECT1:
            return .transportCapableFlag1
        case IPTOS_ECN_ECT0:
            return .transportCapableFlag0
        case IPTOS_ECN_CE:
            return .congestionExperienced
        default:
            return .transportNotCapable
        }
    }
}

extension NIOExplicitCongestionNotificationState {
    #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
    fileprivate static let notCapableValue = IPTOS_ECN_NOTECT
    #else
    fileprivate static let notCapableValue = IPTOS_ECN_NOT_ECT    // Linux
    #endif
    
    func asCInt() -> CInt {
        switch self {
        case .transportNotCapable:
            return .init(NIOExplicitCongestionNotificationState.notCapableValue)
        case .transportCapableFlag0:
            return .init(IPTOS_ECN_ECT0)
        case .transportCapableFlag1:
            return .init(IPTOS_ECN_ECT1)
        case .congestionExperienced:
            return .init(IPTOS_ECN_CE)
        }
    }
}

struct UnsafeOutboundControlBytes {
    private var controlBytes: UnsafeMutableRawBufferPointer
    private var writePosition: size_t = 0
    
    /// Control bytes are captured - this structure must not have a lifetime exceeded them.
    init(controlBytes: UnsafeMutableRawBufferPointer) {
        self.controlBytes = controlBytes
    }
    
    mutating func appendControlMessage<PayloadType>(level: Int32,
                                          type: Int32,
                                          payload: PayloadType) {
        let writableBuffer = UnsafeMutableRawBufferPointer(rebasing: self.controlBytes[writePosition...])
        
        let requiredSize = Posix.cmsgSpace(payloadSize: MemoryLayout.stride(ofValue: payload))
        precondition(writableBuffer.count >= requiredSize, "Insufficient size for cmsghdr and data")
        
        let bufferBase = writableBuffer.baseAddress!
        let cmsghdrPtr = bufferBase.bindMemory(to: cmsghdr.self, capacity: 1)
        cmsghdrPtr.pointee.cmsg_level = level
        cmsghdrPtr.pointee.cmsg_type = type
        cmsghdrPtr.pointee.cmsg_len = .init(Posix.cmsgLen(payloadSize: MemoryLayout.size(ofValue: payload)))
        
        let dataPointer = Posix.cmsgData(for: .some(cmsghdrPtr))
        precondition(dataPointer!.count >= MemoryLayout<PayloadType>.stride)
        let dataPointerBase = dataPointer!.baseAddress!
        let dataPointerTyped = dataPointerBase.bindMemory(to: PayloadType.self, capacity: 1)
        dataPointerTyped.pointee = payload
        
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
    /// - address:  Either local or remote will do, we just use it for extracting the right protocol.
    internal mutating func appendExplicitCongestionState(metadata: AddressedEnvelope<ByteBuffer>.Metadata?,
                                                         address: SocketAddress?) {
        if let metadata = metadata {
            switch address {
            case .some(.v4):
                self.appendControlMessage(level: .init(IPPROTO_IP),
                                          type: IP_TOS,
                                          payload: metadata.ecnState.asCInt())
            case .some(.v6):
                self.appendControlMessage(level: .init(IPPROTO_IPV6),
                                          type: IPV6_TCLASS,
                                          payload: metadata.ecnState.asCInt())
            default:
                // Nothing to do - if we get here the user is probably making a mistake.
                break
            }
        }
    }
}

extension AddressedEnvelope.Metadata {
    /// It's assumed the caller has checked that congestion information is required before calling.
    internal init(from controlMessagesReceived: UnsafeControlMessageCollection) {
        var controlMessageReceiver = ControlMessageReceiver()
        controlMessagesReceived.forEach { controlMessage in controlMessageReceiver.receiveMessage(controlMessage) }
        self.init(ecnState: controlMessageReceiver.ecnValue)
    }
}
