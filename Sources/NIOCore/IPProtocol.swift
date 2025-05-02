//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// In the Internet Protocol version 4 (IPv4) [RFC791] there is a field
/// called "Protocol" to identify the next level protocol.  This is an 8
/// bit field.  In Internet Protocol version 6 (IPv6) [RFC8200], this field
/// is called the "Next Header" field.
public struct NIOIPProtocol: RawRepresentable, Hashable, Sendable {
    public typealias RawValue = UInt8
    public var rawValue: RawValue

    @inlinable
    public init(rawValue: RawValue) {
        self.rawValue = rawValue
    }
}

extension NIOIPProtocol {
    /// - precondition: `rawValue` must fit into an `UInt8`
    public init(_ rawValue: Int) {
        self.init(rawValue: UInt8(rawValue))
    }
}

// Subset of https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml with an RFC
extension NIOIPProtocol {
    /// IPv6 Hop-by-Hop Option - [RFC8200]
    @inlinable
    public static var hopopt: NIOIPProtocol {
        Self(rawValue: 0)
    }
    /// Internet Control Message - [RFC792]
    @inlinable
    public static var icmp: NIOIPProtocol {
        Self(rawValue: 1)
    }
    /// Internet Group Management - [RFC1112]
    @inlinable
    public static var igmp: NIOIPProtocol {
        Self(rawValue: 2)
    }
    /// Gateway-to-Gateway - [RFC823]
    @inlinable
    public static var ggp: NIOIPProtocol {
        Self(rawValue: 3)
    }
    /// IPv4 encapsulation - [RFC2003]
    @inlinable
    public static var ipv4: NIOIPProtocol {
        Self(rawValue: 4)
    }
    /// Stream - [RFC1190][RFC1819]
    @inlinable
    public static var st: NIOIPProtocol {
        Self(rawValue: 5)
    }
    /// Transmission Control - [RFC9293]
    @inlinable
    public static var tcp: NIOIPProtocol {
        Self(rawValue: 6)
    }
    /// Exterior Gateway Protocol - [RFC888][David_Mills]
    @inlinable
    public static var egp: NIOIPProtocol {
        Self(rawValue: 8)
    }
    /// Network Voice Protocol - [RFC741][Steve_Casner]
    @inlinable
    public static var nvpIi: NIOIPProtocol {
        Self(rawValue: 11)
    }
    /// User Datagram - [RFC768][Jon_Postel]
    @inlinable
    public static var udp: NIOIPProtocol {
        Self(rawValue: 17)
    }
    /// Host Monitoring - [RFC869][Bob_Hinden]
    @inlinable
    public static var hmp: NIOIPProtocol {
        Self(rawValue: 20)
    }
    /// Reliable Data Protocol - [RFC908][Bob_Hinden]
    @inlinable
    public static var rdp: NIOIPProtocol {
        Self(rawValue: 27)
    }
    /// Internet Reliable Transaction - [RFC938][Trudy_Miller]
    @inlinable
    public static var irtp: NIOIPProtocol {
        Self(rawValue: 28)
    }
    /// ISO Transport Protocol Class 4 - [RFC905][<mystery contact>]
    @inlinable
    public static var isoTp4: NIOIPProtocol {
        Self(rawValue: 29)
    }
    /// Bulk Data Transfer Protocol - [RFC969][David_Clark]
    @inlinable
    public static var netblt: NIOIPProtocol {
        Self(rawValue: 30)
    }
    /// Datagram Congestion Control Protocol - [RFC4340]
    @inlinable
    public static var dccp: NIOIPProtocol {
        Self(rawValue: 33)
    }
    /// IPv6 encapsulation - [RFC2473]
    @inlinable
    public static var ipv6: NIOIPProtocol {
        Self(rawValue: 41)
    }
    /// Reservation Protocol - [RFC2205][RFC3209][Bob_Braden]
    @inlinable
    public static var rsvp: NIOIPProtocol {
        Self(rawValue: 46)
    }
    /// Generic Routing Encapsulation - [RFC2784][Tony_Li]
    @inlinable
    public static var gre: NIOIPProtocol {
        Self(rawValue: 47)
    }
    /// Dynamic Source Routing Protocol - [RFC4728]
    @inlinable
    public static var dsr: NIOIPProtocol {
        Self(rawValue: 48)
    }
    /// Encap Security Payload - [RFC4303]
    @inlinable
    public static var esp: NIOIPProtocol {
        Self(rawValue: 50)
    }
    /// Authentication Header - [RFC4302]
    @inlinable
    public static var ah: NIOIPProtocol {
        Self(rawValue: 51)
    }
    /// NBMA Address Resolution Protocol - [RFC1735]
    @inlinable
    public static var narp: NIOIPProtocol {
        Self(rawValue: 54)
    }
    /// ICMP for IPv6 - [RFC8200]
    @inlinable
    public static var ipv6Icmp: NIOIPProtocol {
        Self(rawValue: 58)
    }
    /// No Next Header for IPv6 - [RFC8200]
    @inlinable
    public static var ipv6Nonxt: NIOIPProtocol {
        Self(rawValue: 59)
    }
    /// Destination Options for IPv6 - [RFC8200]
    @inlinable
    public static var ipv6Opts: NIOIPProtocol {
        Self(rawValue: 60)
    }
    /// EIGRP - [RFC7868]
    @inlinable
    public static var eigrp: NIOIPProtocol {
        Self(rawValue: 88)
    }
    /// OSPFIGP - [RFC1583][RFC2328][RFC5340][John_Moy]
    @inlinable
    public static var ospfigp: NIOIPProtocol {
        Self(rawValue: 89)
    }
    /// Ethernet-within-IP Encapsulation - [RFC3378]
    @inlinable
    public static var etherip: NIOIPProtocol {
        Self(rawValue: 97)
    }
    /// Encapsulation Header - [RFC1241][Robert_Woodburn]
    @inlinable
    public static var encap: NIOIPProtocol {
        Self(rawValue: 98)
    }
    /// Protocol Independent Multicast - [RFC7761][Dino_Farinacci]
    @inlinable
    public static var pim: NIOIPProtocol {
        Self(rawValue: 103)
    }
    /// IP Payload Compression Protocol - [RFC2393]
    @inlinable
    public static var ipcomp: NIOIPProtocol {
        Self(rawValue: 108)
    }
    /// Virtual Router Redundancy Protocol - [RFC5798]
    @inlinable
    public static var vrrp: NIOIPProtocol {
        Self(rawValue: 112)
    }
    /// Layer Two Tunneling Protocol - [RFC3931][Bernard_Aboba]
    @inlinable
    public static var l2tp: NIOIPProtocol {
        Self(rawValue: 115)
    }
    /// Fibre Channel - [Murali_Rajagopal][RFC6172]
    @inlinable
    public static var fc: NIOIPProtocol {
        Self(rawValue: 133)
    }
    /// MANET Protocols - [RFC5498]
    @inlinable
    public static var manet: NIOIPProtocol {
        Self(rawValue: 138)
    }
    /// Host Identity Protocol - [RFC7401]
    @inlinable
    public static var hip: NIOIPProtocol {
        Self(rawValue: 139)
    }
    /// Shim6 Protocol - [RFC5533]
    @inlinable
    public static var shim6: NIOIPProtocol {
        Self(rawValue: 140)
    }
    /// Wrapped Encapsulating Security Payload - [RFC5840]
    @inlinable
    public static var wesp: NIOIPProtocol {
        Self(rawValue: 141)
    }
    /// Robust Header Compression - [RFC5858]
    @inlinable
    public static var rohc: NIOIPProtocol {
        Self(rawValue: 142)
    }
    /// Ethernet - [RFC8986]
    @inlinable
    public static var ethernet: NIOIPProtocol {
        Self(rawValue: 143)
    }
    /// AGGFRAG encapsulation payload for ESP - [RFC-ietf-ipsecme-iptfs-19]
    @inlinable
    public static var aggfrag: NIOIPProtocol {
        Self(rawValue: 144)
    }
}

extension NIOIPProtocol: CustomStringConvertible {
    private var name: String? {
        switch self {
        case .hopopt: return "IPv6 Hop-by-Hop Option"
        case .icmp: return "Internet Control Message"
        case .igmp: return "Internet Group Management"
        case .ggp: return "Gateway-to-Gateway"
        case .ipv4: return "IPv4 encapsulation"
        case .st: return "Stream"
        case .tcp: return "Transmission Control"
        case .egp: return "Exterior Gateway Protocol"
        case .nvpIi: return "Network Voice Protocol"
        case .udp: return "User Datagram"
        case .hmp: return "Host Monitoring"
        case .rdp: return "Reliable Data Protocol"
        case .irtp: return "Internet Reliable Transaction"
        case .isoTp4: return "ISO Transport Protocol Class 4"
        case .netblt: return "Bulk Data Transfer Protocol"
        case .dccp: return "Datagram Congestion Control Protocol"
        case .ipv6: return "IPv6 encapsulation"
        case .rsvp: return "Reservation Protocol"
        case .gre: return "Generic Routing Encapsulation"
        case .dsr: return "Dynamic Source Routing Protocol"
        case .esp: return "Encap Security Payload"
        case .ah: return "Authentication Header"
        case .narp: return "NBMA Address Resolution Protocol"
        case .ipv6Icmp: return "ICMP for IPv6"
        case .ipv6Nonxt: return "No Next Header for IPv6"
        case .ipv6Opts: return "Destination Options for IPv6"
        case .eigrp: return "EIGRP"
        case .ospfigp: return "OSPFIGP"
        case .etherip: return "Ethernet-within-IP Encapsulation"
        case .encap: return "Encapsulation Header"
        case .pim: return "Protocol Independent Multicast"
        case .ipcomp: return "IP Payload Compression Protocol"
        case .vrrp: return "Virtual Router Redundancy Protocol"
        case .l2tp: return "Layer Two Tunneling Protocol"
        case .fc: return "Fibre Channel"
        case .manet: return "MANET Protocols"
        case .hip: return "Host Identity Protocol"
        case .shim6: return "Shim6 Protocol"
        case .wesp: return "Wrapped Encapsulating Security Payload"
        case .rohc: return "Robust Header Compression"
        case .ethernet: return "Ethernet"
        case .aggfrag: return "AGGFRAG encapsulation payload for ESP"
        default: return nil
        }
    }

    public var description: String {
        let name = self.name ?? "Unknown Protocol"
        return "\(name) - \(rawValue)"
    }
}
