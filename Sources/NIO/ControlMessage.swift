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
    var data: UnsafeBufferPointer<UInt8>?
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
                    valuePtr.copyMemory(from: UnsafeRawBufferPointer(data))
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
