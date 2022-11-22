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
public struct NIOIPProtocol: RawRepresentable, Hashable {
    public typealias RawValue = UInt8
    public var rawValue: RawValue
    
    @inlinable
    public init(rawValue: RawValue) {
        self.rawValue = rawValue
    }
}

// Subset of https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml with an RFC
extension NIOIPProtocol {
    /// IPv6 Hop-by-Hop Option - [RFC8200]
    public static let hopopt = Self(rawValue: 0)
    /// Internet Control Message - [RFC792]
    public static let icmp = Self(rawValue: 1)
    /// Internet Group Management - [RFC1112]
    public static let igmp = Self(rawValue: 2)
    /// Gateway-to-Gateway - [RFC823]
    public static let ggp = Self(rawValue: 3)
    /// IPv4 encapsulation - [RFC2003]
    public static let ipv4 = Self(rawValue: 4)
    /// Stream - [RFC1190][RFC1819]
    public static let st = Self(rawValue: 5)
    /// Transmission Control - [RFC9293]
    public static let tcp = Self(rawValue: 6)
    /// Exterior Gateway Protocol - [RFC888][David_Mills]
    public static let egp = Self(rawValue: 8)
    /// Network Voice Protocol - [RFC741][Steve_Casner]
    public static let nvpIi = Self(rawValue: 11)
    /// User Datagram - [RFC768][Jon_Postel]
    public static let udp = Self(rawValue: 17)
    /// Host Monitoring - [RFC869][Bob_Hinden]
    public static let hmp = Self(rawValue: 20)
    /// Reliable Data Protocol - [RFC908][Bob_Hinden]
    public static let rdp = Self(rawValue: 27)
    /// Internet Reliable Transaction - [RFC938][Trudy_Miller]
    public static let irtp = Self(rawValue: 28)
    /// ISO Transport Protocol Class 4 - [RFC905][<mystery contact>]
    public static let isoTp4 = Self(rawValue: 29)
    /// Bulk Data Transfer Protocol - [RFC969][David_Clark]
    public static let netblt = Self(rawValue: 30)
    /// Datagram Congestion Control Protocol - [RFC4340]
    public static let dccp = Self(rawValue: 33)
    /// IPv6 encapsulation - [RFC2473]
    public static let ipv6 = Self(rawValue: 41)
    /// Reservation Protocol - [RFC2205][RFC3209][Bob_Braden]
    public static let rsvp = Self(rawValue: 46)
    /// Generic Routing Encapsulation - [RFC2784][Tony_Li]
    public static let gre = Self(rawValue: 47)
    /// Dynamic Source Routing Protocol - [RFC4728]
    public static let dsr = Self(rawValue: 48)
    /// Encap Security Payload - [RFC4303]
    public static let esp = Self(rawValue: 50)
    /// Authentication Header - [RFC4302]
    public static let ah = Self(rawValue: 51)
    /// NBMA Address Resolution Protocol - [RFC1735]
    public static let narp = Self(rawValue: 54)
    /// ICMP for IPv6 - [RFC8200]
    public static let ipv6Icmp = Self(rawValue: 58)
    /// No Next Header for IPv6 - [RFC8200]
    public static let ipv6Nonxt = Self(rawValue: 59)
    /// Destination Options for IPv6 - [RFC8200]
    public static let ipv6Opts = Self(rawValue: 60)
    /// EIGRP - [RFC7868]
    public static let eigrp = Self(rawValue: 88)
    /// OSPFIGP - [RFC1583][RFC2328][RFC5340][John_Moy]
    public static let ospfigp = Self(rawValue: 89)
    /// Ethernet-within-IP Encapsulation - [RFC3378]
    public static let etherip = Self(rawValue: 97)
    /// Encapsulation Header - [RFC1241][Robert_Woodburn]
    public static let encap = Self(rawValue: 98)
    /// Protocol Independent Multicast - [RFC7761][Dino_Farinacci]
    public static let pim = Self(rawValue: 103)
    /// IP Payload Compression Protocol - [RFC2393]
    public static let ipcomp = Self(rawValue: 108)
    /// Virtual Router Redundancy Protocol - [RFC5798]
    public static let vrrp = Self(rawValue: 112)
    /// Layer Two Tunneling Protocol - [RFC3931][Bernard_Aboba]
    public static let l2tp = Self(rawValue: 115)
    /// Fibre Channel - [Murali_Rajagopal][RFC6172]
    public static let fc = Self(rawValue: 133)
    /// MANET Protocols - [RFC5498]
    public static let manet = Self(rawValue: 138)
    /// Host Identity Protocol - [RFC7401]
    public static let hip = Self(rawValue: 139)
    /// Shim6 Protocol - [RFC5533]
    public static let shim6 = Self(rawValue: 140)
    /// Wrapped Encapsulating Security Payload - [RFC5840]
    public static let wesp = Self(rawValue: 141)
    /// Robust Header Compression - [RFC5858]
    public static let rohc = Self(rawValue: 142)
    /// Ethernet - [RFC8986]
    public static let ethernet = Self(rawValue: 143)
    /// AGGFRAG encapsulation payload for ESP - [RFC-ietf-ipsecme-iptfs-19]
    public static let aggfrag = Self(rawValue: 144)
    /// Use for experimentation and testing (253) - [RFC3692]
    public static let useForExperimentationAndTesting1 = Self(rawValue: 253)
    /// Use for experimentation and testing (254) - [RFC3692]
    public static let useForExperimentationAndTesting2 = Self(rawValue: 254)
}
