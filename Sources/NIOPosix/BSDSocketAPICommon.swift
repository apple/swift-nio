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

#if os(Windows)
import ucrt

import let WinSDK.INVALID_SOCKET

import let WinSDK.IP_RECVTOS
import let WinSDK.IPV6_RECVTCLASS

import let WinSDK.SOCK_DGRAM
import let WinSDK.SOCK_STREAM

import struct WinSDK.socklen_t
#endif

protocol _SocketShutdownProtocol {
    var cValue: CInt { get }
}

internal enum Shutdown: _SocketShutdownProtocol {
    case RD
    case WR
    case RDWR
}

extension NIOBSDSocket {
#if os(Windows)
    internal static let invalidHandle: Handle = INVALID_SOCKET
#else
    internal static let invalidHandle: Handle = -1
#endif
}

extension NIOBSDSocket {
    /// Specifies the type of socket.
    internal struct SocketType: RawRepresentable {
        public typealias RawValue = CInt
        public var rawValue: RawValue
        public init(rawValue: RawValue) {
            self.rawValue = rawValue
        }
    }
}

extension NIOBSDSocket.SocketType: Equatable {
}

extension NIOBSDSocket.SocketType: Hashable {
}

// Socket Types
extension NIOBSDSocket.SocketType {
    /// Supports datagrams, which are connectionless, unreliable messages of a
    /// fixed (typically small) maximum length.
    #if os(Linux)
        internal static let datagram: NIOBSDSocket.SocketType =
                NIOBSDSocket.SocketType(rawValue: CInt(SOCK_DGRAM.rawValue))
    #else
        internal static let datagram: NIOBSDSocket.SocketType =
                NIOBSDSocket.SocketType(rawValue: SOCK_DGRAM)
    #endif

    /// Supports reliable, two-way, connection-based byte streams without
    /// duplication of data and without preservation of boundaries.
    #if os(Linux)
        internal static let stream: NIOBSDSocket.SocketType =
                NIOBSDSocket.SocketType(rawValue: CInt(SOCK_STREAM.rawValue))
    #else
        internal static let stream: NIOBSDSocket.SocketType =
                NIOBSDSocket.SocketType(rawValue: SOCK_STREAM)
    #endif
}

// IPv4 Options
extension NIOBSDSocket.Option {
    /// Request that we are passed type of service details when receiving
    /// datagrams.
    ///
    /// Not public as the way to request this is to use
    /// `ChannelOptions.explicitCongestionNotification` which works for both
    /// IPv4 and IPv6.
    static let ip_recv_tos: NIOBSDSocket.Option =
            NIOBSDSocket.Option(rawValue: IP_RECVTOS)

    /// Request that we are passed destination address and the receiving interface index when
    /// receiving datagrams.
    ///
    /// This option is not public as the way to request this is to use
    /// `ChannelOptions.receivePacketInfo` which works for both
    /// IPv4 and IPv6.
    static let ip_recv_pktinfo: NIOBSDSocket.Option =
            NIOBSDSocket.Option(rawValue: Posix.IP_RECVPKTINFO)
}

// IPv6 Options
extension NIOBSDSocket.Option {
    /// Request that we are passed traffic class details when receiving
    /// datagrams.
    ///
    /// Not public as the way to request this is to use
    /// `ChannelOptions.explicitCongestionNotification` which works for both
    /// IPv4 and IPv6.
    static let ipv6_recv_tclass: NIOBSDSocket.Option =
            NIOBSDSocket.Option(rawValue: IPV6_RECVTCLASS)

    /// Request that we are passed destination address and the receiving interface index when
    /// receiving datagrams.
    ///
    /// This option is not public as the way to request this is to use
    /// `ChannelOptions.receivePacketInfo` which works for both
    /// IPv4 and IPv6.
    static let ipv6_recv_pktinfo: NIOBSDSocket.Option =
        NIOBSDSocket.Option(rawValue: Posix.IPV6_RECVPKTINFO)
}

extension NIOBSDSocket {
    /// In the Internet Protocol version 4 (IPv4) [RFC791] there is a field
    /// called "Protocol" to identify the next level protocol.  This is an 8
    /// bit field.  In Internet Protocol version 6 (IPv6) [RFC8200], this field
    /// is called the "Next Header" field.
    public struct ProtocolSubtype: RawRepresentable, Hashable {
        public typealias RawValue = CInt
        public var rawValue: RawValue
        
        @inlinable public init(rawValue: RawValue) {
            self.rawValue = rawValue
        }
    }
}

// Generated with:
//
// import Foundation
//
// let protocols = try String(contentsOf: URL(filePath: "/etc/protocols"))
//
// let regex = #/^([^#].+)\t+(\d+)\t+([\w\-\+/]+)\t*#*\ *(.+)?$/#.anchorsMatchLineEndings()
// for match in protocols.matches(of: regex) {
//     let (_, name, number, _, description) = match.output
//
//     guard let number = CInt(number) else { continue }
//
//     let identifier = name
//         // hyphens to camel case
//         .replacing(#/-([a-z1-9])/#) { match in
//             match.output.1.uppercased()
//         }
//         // 3pc has a number at the front which and therefore an illegal Swift identifier.
//         // This is the only name with a number in the front and we can just hard code a different identifier
//         .replacing("3pc", with: "thirdpc")
//         // tp++ -> tpPlusPlus
//         .replacing("+", with: "Plus")
//         // a/n -> an
//         .replacing(#/[\./]/#, with: "")
//
//
//     if let description {
//         print("/// \(description)")
//     }
//     print("public static let \(identifier) = Self(rawValue: \(number))")
// }
extension NIOBSDSocket.ProtocolSubtype {
    /// internet protocol, pseudo protocol number
    public static let ip = Self(rawValue: 0)
    /// internet control message protocol
    public static let icmp = Self(rawValue: 1)
    /// internet group management protocol
    public static let igmp = Self(rawValue: 2)
    /// gateway-gateway protocol
    public static let ggp = Self(rawValue: 3)
    /// IP encapsulated in IP (officially ``IP'')
    public static let ipencap = Self(rawValue: 4)
    /// ST2 datagram mode (RFC 1819) (officially ``ST'')
    public static let st2 = Self(rawValue: 5)
    /// transmission control protocol
    public static let tcp = Self(rawValue: 6)
    /// CBT, Tony Ballardie <A.Ballardie@cs.ucl.ac.uk>
    public static let cbt = Self(rawValue: 7)
    /// exterior gateway protocol
    public static let egp = Self(rawValue: 8)
    /// any private interior gateway (Cisco: for IGRP)
    public static let igp = Self(rawValue: 9)
    /// BBN RCC Monitoring
    public static let bbnRcc = Self(rawValue: 10)
    /// Network Voice Protocol
    public static let nvp = Self(rawValue: 11)
    /// PARC universal packet protocol
    public static let pup = Self(rawValue: 12)
    /// ARGUS
    public static let argus = Self(rawValue: 13)
    /// EMCON
    public static let emcon = Self(rawValue: 14)
    /// Cross Net Debugger
    public static let xnet = Self(rawValue: 15)
    /// Chaos
    public static let chaos = Self(rawValue: 16)
    /// user datagram protocol
    public static let udp = Self(rawValue: 17)
    /// Multiplexing protocol
    public static let mux = Self(rawValue: 18)
    /// DCN Measurement Subsystems
    public static let dcn = Self(rawValue: 19)
    /// host monitoring protocol
    public static let hmp = Self(rawValue: 20)
    /// packet radio measurement protocol
    public static let prm = Self(rawValue: 21)
    /// Xerox NS IDP
    public static let xnsIdp = Self(rawValue: 22)
    /// Trunk-1
    public static let trunk1 = Self(rawValue: 23)
    /// Trunk-2
    public static let trunk2 = Self(rawValue: 24)
    /// Leaf-1
    public static let leaf1 = Self(rawValue: 25)
    /// Leaf-2
    public static let leaf2 = Self(rawValue: 26)
    /// "reliable datagram" protocol
    public static let rdp = Self(rawValue: 27)
    /// Internet Reliable Transaction Protocol
    public static let irtp = Self(rawValue: 28)
    /// ISO Transport Protocol Class 4
    public static let isoTp4 = Self(rawValue: 29)
    /// Bulk Data Transfer Protocol
    public static let netblt = Self(rawValue: 30)
    /// MFE Network Services Protocol
    public static let mfeNsp = Self(rawValue: 31)
    /// MERIT Internodal Protocol
    public static let meritInp = Self(rawValue: 32)
    /// Datagram Congestion Control Protocol
    public static let dccp = Self(rawValue: 33)
    /// Third Party Connect Protocol
    public static let thirdpc = Self(rawValue: 34)
    /// Inter-Domain Policy Routing Protocol
    public static let idpr = Self(rawValue: 35)
    /// Xpress Tranfer Protocol
    public static let xtp = Self(rawValue: 36)
    /// Datagram Delivery Protocol
    public static let ddp = Self(rawValue: 37)
    /// IDPR Control Message Transport Proto
    public static let idprCmtp = Self(rawValue: 38)
    /// TP++ Transport Protocol
    public static let tpPlusPlus = Self(rawValue: 39)
    /// IL Transport Protocol
    public static let il = Self(rawValue: 40)
    /// ipv6
    public static let ipv6 = Self(rawValue: 41)
    /// Source Demand Routing Protocol
    public static let sdrp = Self(rawValue: 42)
    /// routing header for ipv6
    public static let ipv6Route = Self(rawValue: 43)
    /// fragment header for ipv6
    public static let ipv6Frag = Self(rawValue: 44)
    /// Inter-Domain Routing Protocol
    public static let idrp = Self(rawValue: 45)
    /// Resource ReSerVation Protocol
    public static let rsvp = Self(rawValue: 46)
    /// Generic Routing Encapsulation
    public static let gre = Self(rawValue: 47)
    /// Dynamic Source Routing Protocol
    public static let dsr = Self(rawValue: 48)
    /// BNA
    public static let bna = Self(rawValue: 49)
    /// encapsulating security payload
    public static let esp = Self(rawValue: 50)
    /// authentication header
    public static let ah = Self(rawValue: 51)
    /// Integrated Net Layer Security TUBA
    public static let iNlsp = Self(rawValue: 52)
    /// IP with Encryption
    public static let swipe = Self(rawValue: 53)
    /// NBMA Address Resolution Protocol
    public static let narp = Self(rawValue: 54)
    /// IP Mobility
    public static let mobile = Self(rawValue: 55)
    /// Transport Layer Security Protocol
    public static let tlsp = Self(rawValue: 56)
    /// SKIP
    public static let skip = Self(rawValue: 57)
    /// icmp6    # ICMP for IPv6
    public static let ipv6Icmp = Self(rawValue: 58)
    /// no next header for ipv6
    public static let ipv6Nonxt = Self(rawValue: 59)
    /// destination options for ipv6
    public static let ipv6Opts = Self(rawValue: 60)
    /// CFTP
    public static let cftp = Self(rawValue: 62)
    /// SATNET and Backroom EXPAK
    public static let satExpak = Self(rawValue: 64)
    /// Kryptolan
    public static let kryptolan = Self(rawValue: 65)
    /// MIT Remote Virtual Disk Protocol
    public static let rvd = Self(rawValue: 66)
    /// Internet Pluribus Packet Core
    public static let ippc = Self(rawValue: 67)
    /// SATNET Monitoring
    public static let satMon = Self(rawValue: 69)
    /// VISA Protocol
    public static let visa = Self(rawValue: 70)
    /// Internet Packet Core Utility
    public static let ipcv = Self(rawValue: 71)
    /// Computer Protocol Network Executive
    public static let cpnx = Self(rawValue: 72)
    /// Computer Protocol Heart Beat
    public static let cphb = Self(rawValue: 73)
    /// Wang Span Network
    public static let wsn = Self(rawValue: 74)
    /// Packet Video Protocol
    public static let pvp = Self(rawValue: 75)
    /// Backroom SATNET Monitoring
    public static let brSatMon = Self(rawValue: 76)
    /// SUN ND PROTOCOL-Temporary
    public static let sunNd = Self(rawValue: 77)
    /// WIDEBAND Monitoring
    public static let wbMon = Self(rawValue: 78)
    /// WIDEBAND EXPAK
    public static let wbExpak = Self(rawValue: 79)
    /// ISO Internet Protocol
    public static let isoIp = Self(rawValue: 80)
    /// Versatile Message Transport
    public static let vmtp = Self(rawValue: 81)
    /// SECURE-VMTP
    public static let secureVmtp = Self(rawValue: 82)
    /// VINES
    public static let vines = Self(rawValue: 83)
    /// TTP
    public static let ttp = Self(rawValue: 84)
    /// NSFNET-IGP
    public static let nsfnetIgp = Self(rawValue: 85)
    /// Dissimilar Gateway Protocol
    public static let dgp = Self(rawValue: 86)
    /// TCF
    public static let tcf = Self(rawValue: 87)
    /// Enhanced Interior Routing Protocol (Cisco)
    public static let eigrp = Self(rawValue: 88)
    /// Open Shortest Path First IGP
    public static let ospf = Self(rawValue: 89)
    /// Sprite RPC Protocol
    public static let spriteRpc = Self(rawValue: 90)
    /// Locus Address Resolution Protocol
    public static let larp = Self(rawValue: 91)
    /// Multicast Transport Protocol
    public static let mtp = Self(rawValue: 92)
    /// .25        # AX.25 Frames
    public static let ax25 = Self(rawValue: 93)
    /// Yet Another IP encapsulation
    public static let ipip = Self(rawValue: 94)
    /// Mobile Internetworking Control Pro.
    public static let micp = Self(rawValue: 95)
    /// Semaphore Communications Sec. Pro.
    public static let sccSp = Self(rawValue: 96)
    /// Ethernet-within-IP Encapsulation
    public static let etherip = Self(rawValue: 97)
    /// Yet Another IP encapsulation
    public static let encap = Self(rawValue: 98)
    /// GMTP
    public static let gmtp = Self(rawValue: 100)
    /// Ipsilon Flow Management Protocol
    public static let ifmp = Self(rawValue: 101)
    /// PNNI over IP
    public static let pnni = Self(rawValue: 102)
    /// Protocol Independent Multicast
    public static let pim = Self(rawValue: 103)
    /// ARIS
    public static let aris = Self(rawValue: 104)
    /// SCPS
    public static let scps = Self(rawValue: 105)
    /// QNX
    public static let qnx = Self(rawValue: 106)
    /// Active Networks
    public static let an = Self(rawValue: 107)
    /// IP Payload Compression Protocol
    public static let ipcomp = Self(rawValue: 108)
    /// Sitara Networks Protocol
    public static let snp = Self(rawValue: 109)
    /// Compaq Peer Protocol
    public static let compaqPeer = Self(rawValue: 110)
    /// IPX in IP
    public static let ipxInIp = Self(rawValue: 111)
    /// vrrp        # Common Address Redundancy Protocol
    public static let carp = Self(rawValue: 112)
    /// PGM Reliable Transport Protocol
    public static let pgm = Self(rawValue: 113)
    /// Layer Two Tunneling Protocol
    public static let l2tp = Self(rawValue: 115)
    /// D-II Data Exchange
    public static let ddx = Self(rawValue: 116)
    /// Interactive Agent Transfer Protocol
    public static let iatp = Self(rawValue: 117)
    /// Schedule Transfer Protocol
    public static let stp = Self(rawValue: 118)
    /// SpectraLink Radio Protocol
    public static let srp = Self(rawValue: 119)
    /// UTI
    public static let uti = Self(rawValue: 120)
    /// Simple Message Protocol
    public static let smp = Self(rawValue: 121)
    /// SM
    public static let sm = Self(rawValue: 122)
    /// Performance Transparency Protocol
    public static let ptp = Self(rawValue: 123)
    /// ISIS over IPv4
    public static let isis = Self(rawValue: 124)
    public static let fire = Self(rawValue: 125)
    /// Combat Radio Transport Protocol
    public static let crtp = Self(rawValue: 126)
    /// Combat Radio User Datagram
    public static let crudp = Self(rawValue: 127)
    public static let sscopmce = Self(rawValue: 128)
    public static let iplt = Self(rawValue: 129)
    /// Secure Packet Shield
    public static let sps = Self(rawValue: 130)
    /// Private IP Encapsulation within IP
    public static let pipe = Self(rawValue: 131)
    /// Stream Control Transmission Protocol
    public static let sctp = Self(rawValue: 132)
    /// Fibre Channel
    public static let fc = Self(rawValue: 133)
    /// Aggregation of RSVP for IP reservations
    public static let rsvpE2eIgnore = Self(rawValue: 134)
    /// Mobility Support in IPv6
    public static let mobilityHeader = Self(rawValue: 135)
    /// The UDP-Lite Protocol
    public static let udplite = Self(rawValue: 136)
    /// Encapsulating MPLS in IP
    public static let mplsInIp = Self(rawValue: 137)
    /// MANET Protocols (RFC5498)
    public static let manet = Self(rawValue: 138)
    /// Host Identity Protocol (RFC5201)
    public static let hip = Self(rawValue: 139)
    /// Shim6 Protocol (RFC5533)
    public static let shim6 = Self(rawValue: 140)
    /// Wrapped Encapsulating Security Payload (RFC5840)
    public static let wesp = Self(rawValue: 141)
    /// Robust Header Compression (RFC5858)
    public static let rohc = Self(rawValue: 142)
    /// PF Synchronization
    public static let pfsync = Self(rawValue: 240)
    /// Divert pseudo-protocol [non IANA]
    public static let divert = Self(rawValue: 258)
}


/// This protocol defines the methods that are expected to be found on
/// `NIOBSDSocket`. While defined as a protocol there is no expectation that any
/// object other than `NIOBSDSocket` will implement this protocol: instead, this
/// protocol acts as a reference for what new supported operating systems must
/// implement.
protocol _BSDSocketProtocol {
    static func accept(socket s: NIOBSDSocket.Handle,
                       address addr: UnsafeMutablePointer<sockaddr>?,
                       address_len addrlen: UnsafeMutablePointer<socklen_t>?) throws -> NIOBSDSocket.Handle?

    static func bind(socket s: NIOBSDSocket.Handle,
                     address addr: UnsafePointer<sockaddr>,
                     address_len namelen: socklen_t) throws

    static func close(socket s: NIOBSDSocket.Handle) throws

    static func connect(socket s: NIOBSDSocket.Handle,
                        address name: UnsafePointer<sockaddr>,
                        address_len namelen: socklen_t) throws -> Bool

    static func getpeername(socket s: NIOBSDSocket.Handle,
                            address name: UnsafeMutablePointer<sockaddr>,
                            address_len namelen: UnsafeMutablePointer<socklen_t>) throws

    static func getsockname(socket s: NIOBSDSocket.Handle,
                            address name: UnsafeMutablePointer<sockaddr>,
                            address_len namelen: UnsafeMutablePointer<socklen_t>) throws

    static func getsockopt(socket: NIOBSDSocket.Handle,
                           level: NIOBSDSocket.OptionLevel,
                           option_name optname: NIOBSDSocket.Option,
                           option_value optval: UnsafeMutableRawPointer,
                           option_len optlen: UnsafeMutablePointer<socklen_t>) throws

    static func listen(socket s: NIOBSDSocket.Handle, backlog: CInt) throws

    static func recv(socket s: NIOBSDSocket.Handle,
                     buffer buf: UnsafeMutableRawPointer,
                     length len: size_t) throws -> IOResult<size_t>

    // NOTE: this should return a `ssize_t`, however, that is not a standard
    // type, and defining that type is difficult.  Opt to return a `size_t`
    // which is the same size, but is unsigned.
    static func recvmsg(socket: NIOBSDSocket.Handle,
                        msgHdr: UnsafeMutablePointer<msghdr>, flags: CInt)
            throws -> IOResult<size_t>

    // NOTE: this should return a `ssize_t`, however, that is not a standard
    // type, and defining that type is difficult.  Opt to return a `size_t`
    // which is the same size, but is unsigned.
    static func sendmsg(socket: NIOBSDSocket.Handle,
                        msgHdr: UnsafePointer<msghdr>, flags: CInt)
            throws -> IOResult<size_t>

    static func send(socket s: NIOBSDSocket.Handle,
                     buffer buf: UnsafeRawPointer,
                     length len: size_t) throws -> IOResult<size_t>

    static func setsockopt(socket: NIOBSDSocket.Handle,
                           level: NIOBSDSocket.OptionLevel,
                           option_name optname: NIOBSDSocket.Option,
                           option_value optval: UnsafeRawPointer,
                           option_len optlen: socklen_t) throws

    static func shutdown(socket: NIOBSDSocket.Handle, how: Shutdown) throws

    static func socket(domain af: NIOBSDSocket.ProtocolFamily,
                       type: NIOBSDSocket.SocketType,
                       protocolSubtype: NIOBSDSocket.ProtocolSubtype) throws -> NIOBSDSocket.Handle

    static func recvmmsg(socket: NIOBSDSocket.Handle,
                         msgvec: UnsafeMutablePointer<MMsgHdr>,
                         vlen: CUnsignedInt,
                         flags: CInt,
                         timeout: UnsafeMutablePointer<timespec>?) throws -> IOResult<Int>

    static func sendmmsg(socket: NIOBSDSocket.Handle,
                         msgvec: UnsafeMutablePointer<MMsgHdr>,
                         vlen: CUnsignedInt,
                         flags: CInt) throws -> IOResult<Int>

    // NOTE: this should return a `ssize_t`, however, that is not a standard
    // type, and defining that type is difficult.  Opt to return a `size_t`
    // which is the same size, but is unsigned.
    static func pread(socket: NIOBSDSocket.Handle,
                      pointer: UnsafeMutableRawPointer,
                      size: size_t,
                      offset: off_t) throws -> IOResult<size_t>

    // NOTE: this should return a `ssize_t`, however, that is not a standard
    // type, and defining that type is difficult.  Opt to return a `size_t`
    // which is the same size, but is unsigned.
    static func pwrite(socket: NIOBSDSocket.Handle,
                       pointer: UnsafeRawPointer,
                       size: size_t,
                       offset: off_t) throws -> IOResult<size_t>

#if !os(Windows)
    // NOTE: We do not support this on Windows as WSAPoll behaves differently
    // from poll with reporting of failed connections (Connect Report 309411),
    // which recommended that you use NetAPI instead.
    //
    // This is safe to exclude as this is a testing-only API.
    static func poll(fds: UnsafeMutablePointer<pollfd>, nfds: nfds_t,
                     timeout: CInt) throws -> CInt
#endif

    static func sendfile(socket s: NIOBSDSocket.Handle,
                         fd: CInt,
                         offset: off_t,
                         len: off_t) throws -> IOResult<Int>

    // MARK: non-BSD APIs added by NIO

    static func setNonBlocking(socket: NIOBSDSocket.Handle) throws

    static func cleanupUnixDomainSocket(atPath path: String) throws
}

/// If this extension is hitting a compile error, your platform is missing one
/// of the functions defined above!
extension NIOBSDSocket: _BSDSocketProtocol { }

/// This protocol defines the methods that are expected to be found on
/// `NIOBSDControlMessage`. While defined as a protocol there is no expectation
/// that any object other than `NIOBSDControlMessage` will implement this
/// protocol: instead, this protocol acts as a reference for what new supported
/// operating systems must implement.
protocol _BSDSocketControlMessageProtocol {
    static func firstHeader(inside msghdr: UnsafePointer<msghdr>)
            -> UnsafeMutablePointer<cmsghdr>?

    static func nextHeader(inside msghdr: UnsafeMutablePointer<msghdr>,
                           after: UnsafeMutablePointer<cmsghdr>)
            -> UnsafeMutablePointer<cmsghdr>?

    static func data(for header: UnsafePointer<cmsghdr>)
            -> UnsafeRawBufferPointer?

    static func data(for header: UnsafeMutablePointer<cmsghdr>)
            -> UnsafeMutableRawBufferPointer?

    static func length(payloadSize: size_t) -> size_t

    static func space(payloadSize: size_t) -> size_t
}

/// If this extension is hitting a compile error, your platform is missing one
/// of the functions defined above!
enum NIOBSDSocketControlMessage: _BSDSocketControlMessageProtocol { }

/// The requested UDS path exists and has wrong type (not a socket).
public struct UnixDomainSocketPathWrongType: Error {}
