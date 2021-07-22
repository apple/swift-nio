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

#if os(Windows)
import ucrt

import let WinSDK.AF_INET
import let WinSDK.AF_INET6
import let WinSDK.AF_UNIX

import let WinSDK.FIONBIO

import let WinSDK.INET_ADDRSTRLEN
import let WinSDK.INET6_ADDRSTRLEN

import let WinSDK.INVALID_HANDLE_VALUE
import let WinSDK.INVALID_SOCKET

import let WinSDK.IPPROTO_IP
import let WinSDK.IPPROTO_IPV6
import let WinSDK.IPPROTO_TCP

import let WinSDK.IP_ADD_MEMBERSHIP
import let WinSDK.IP_DROP_MEMBERSHIP
import let WinSDK.IP_MULTICAST_IF
import let WinSDK.IP_MULTICAST_LOOP
import let WinSDK.IP_MULTICAST_TTL

import let WinSDK.IPV6_JOIN_GROUP
import let WinSDK.IPV6_LEAVE_GROUP
import let WinSDK.IPV6_MULTICAST_HOPS
import let WinSDK.IPV6_MULTICAST_IF
import let WinSDK.IPV6_MULTICAST_LOOP
import let WinSDK.IPV6_V6ONLY

import let WinSDK.PF_INET
import let WinSDK.PF_INET6
import let WinSDK.PF_UNIX

import let WinSDK.TCP_NODELAY

import let WinSDK.SD_BOTH
import let WinSDK.SD_RECEIVE
import let WinSDK.SD_SEND

import let WinSDK.SO_ERROR
import let WinSDK.SO_KEEPALIVE
import let WinSDK.SO_LINGER
import let WinSDK.SO_RCVBUF
import let WinSDK.SO_RCVTIMEO
import let WinSDK.SO_REUSEADDR
import let WinSDK.SO_REUSE_UNICASTPORT

import let WinSDK.SOL_SOCKET

import let WinSDK.SOCK_DGRAM
import let WinSDK.SOCK_STREAM

import let WinSDK.SOCKET_ERROR

import let WinSDK.TF_USE_KERNEL_APC

import func WinSDK.accept
import func WinSDK.bind
import func WinSDK.closesocket
import func WinSDK.connect
import func WinSDK.getpeername
import func WinSDK.getsockname
import func WinSDK.ioctlsocket
import func WinSDK.listen
import func WinSDK.shutdown
import func WinSDK.socket
import func WinSDK.GetLastError
import func WinSDK.ReadFile
import func WinSDK.TransmitFile
import func WinSDK.WriteFile
import func WinSDK.WSAGetLastError
import func WinSDK.WSAIoctl

import struct WinSDK.socklen_t
import struct WinSDK.u_long
import struct WinSDK.DWORD
import struct WinSDK.HANDLE
import struct WinSDK.LINGER
import struct WinSDK.OVERLAPPED
import struct WinSDK.SOCKADDR
import struct WinSDK.SOCKADDR_IN
import struct WinSDK.SOCKADDR_IN6
import struct WinSDK.SOCKADDR_UN
import struct WinSDK.SOCKADDR_STORAGE

import typealias WinSDK.LPFN_WSARECVMSG

internal typealias sockaddr_in = SOCKADDR_IN
internal typealias sockaddr_in6 = SOCKADDR_IN6
internal typealias sockaddr_un = SOCKADDR_UN
internal typealias sockaddr_storage = SOCKADDR_STORAGE

public typealias linger = LINGER

fileprivate var IOC_IN: DWORD {
  0x8000_0000
}

fileprivate var IOC_OUT: DWORD {
  0x4000_0000
}

fileprivate var IOC_INOUT: DWORD {
  IOC_IN | IOC_OUT
}

fileprivate var IOC_WS2: DWORD {
  0x0800_0000
}

fileprivate func _WSAIORW(_ x: DWORD, _ y: DWORD) -> DWORD {
  IOC_INOUT | x | y
}

fileprivate var SIO_GET_EXTENSION_FUNCTION_POINTER: DWORD {
  _WSAIORW(IOC_WS2, 6)
}

fileprivate var WSAID_WSARECVMSG: _GUID {
  _GUID(Data1: 0xf689d7c8, Data2: 0x6f1f, Data3: 0x436b,
        Data4: (0x8a, 0x53, 0xe5, 0x4f, 0xe3, 0x51, 0xc3, 0x22))
}

fileprivate var WSAID_WSASENDMSG: _GUID {
  _GUID(Data1: 0xa441e712, Data2: 0x754f, Data3: 0x43ca,
        Data4: (0x84,0xa7,0x0d,0xee,0x44,0xcf,0x60,0x6d))
}

// TODO(compnerd) rather than query the `WSARecvMsg` and `WSASendMsg` on each
// message, we should query that and cache the value.  This requires
// understanding the lifetime validity of the pointer.
// TODO(compnerd) create a simpler shared wrapper to query the extension
// function from WinSock and de-duplicate the operations in
// `NIOBSDSocketAPI.recvmsg` and `NIOBSDSocketAPI.sendmsg`.

import CNIOWindows

extension Shutdown {
    internal var cValue: CInt {
        switch self {
        case .RD:
            return WinSDK.SD_RECEIVE
        case .WR:
            return WinSDK.SD_SEND
        case .RDWR:
            return WinSDK.SD_BOTH
        }
    }
}

// MARK: _BSDSocketProtocol implementation
extension NIOBSDSocket {
    @inline(never)
    static func accept(socket s: NIOBSDSocket.Handle,
                       address addr: UnsafeMutablePointer<sockaddr>?,
                       address_len addrlen: UnsafeMutablePointer<socklen_t>?) throws -> NIOBSDSocket.Handle? {
        let socket: NIOBSDSocket.Handle = WinSDK.accept(s, addr, addrlen)
        if socket == WinSDK.INVALID_SOCKET {
            throw IOError(winsock: WSAGetLastError(), reason: "accept")
        }
        return socket
    }

    @inline(never)
    static func bind(socket s: NIOBSDSocket.Handle,
                     address addr: UnsafePointer<sockaddr>,
                     address_len namelen: socklen_t) throws {
        if WinSDK.bind(s, addr, namelen) == SOCKET_ERROR {
            throw IOError(winsock: WSAGetLastError(), reason: "bind")
        }
    }

    @inline(never)
    static func close(socket s: NIOBSDSocket.Handle) throws {
        if WinSDK.closesocket(s) == SOCKET_ERROR {
            throw IOError(winsock: WSAGetLastError(), reason: "close")
        }
    }

    @inline(never)
    static func connect(socket s: NIOBSDSocket.Handle,
                        address name: UnsafePointer<sockaddr>,
                        address_len namelen: socklen_t) throws -> Bool {
        if WinSDK.connect(s, name, namelen) == SOCKET_ERROR {
            let iResult = WSAGetLastError()
            if iResult == WSAEWOULDBLOCK { return true }
            throw IOError(winsock: WSAGetLastError(), reason: "connect")
        }
        return true
    }

    @inline(never)
    static func getpeername(socket s: NIOBSDSocket.Handle,
                            address name: UnsafeMutablePointer<sockaddr>,
                            address_len namelen: UnsafeMutablePointer<socklen_t>) throws {
        if WinSDK.getpeername(s, name, namelen) == SOCKET_ERROR {
            throw IOError(winsock: WSAGetLastError(), reason: "getpeername")
        }
    }

    @inline(never)
    static func getsockname(socket s: NIOBSDSocket.Handle,
                            address name: UnsafeMutablePointer<sockaddr>,
                            address_len namelen: UnsafeMutablePointer<socklen_t>) throws {
        if WinSDK.getsockname(s, name, namelen) == SOCKET_ERROR {
            throw IOError(winsock: WSAGetLastError(), reason: "getsockname")
        }
    }

    @inline(never)
    static func getsockopt(socket: NIOBSDSocket.Handle,
                           level: NIOBSDSocket.OptionLevel,
                           option_name optname: NIOBSDSocket.Option,
                           option_value optval: UnsafeMutableRawPointer,
                           option_len optlen: UnsafeMutablePointer<socklen_t>) throws {
        if CNIOWindows_getsockopt(socket, level.rawValue, optname.rawValue,
                                  optval, optlen) == SOCKET_ERROR {
            throw IOError(winsock: WSAGetLastError(), reason: "getsockopt")
        }
    }

    @inline(never)
    static func listen(socket s: NIOBSDSocket.Handle, backlog: CInt) throws {
        if WinSDK.listen(s, backlog) == SOCKET_ERROR {
            throw IOError(winsock: WSAGetLastError(), reason: "listen")
        }
    }

    @inline(never)
    static func recv(socket s: NIOBSDSocket.Handle,
                     buffer buf: UnsafeMutableRawPointer,
                     length len: size_t) throws -> IOResult<size_t> {
        let iResult: CInt = CNIOWindows_recv(s, buf, CInt(len), 0)
        if iResult == SOCKET_ERROR {
            throw IOError(winsock: WSAGetLastError(), reason: "recv")
        }
        return .processed(size_t(iResult))
    }

    @inline(never)
    static func recvmsg(socket s: NIOBSDSocket.Handle,
                        msgHdr lpMsg: UnsafeMutablePointer<msghdr>,
                        flags: CInt)
            throws -> IOResult<size_t> {
        // TODO(compnerd) see comment above
        var InBuffer = WSAID_WSARECVMSG
        var pfnWSARecvMsg: LPFN_WSARECVMSG?
        var cbBytesReturned: DWORD = 0
        if WinSDK.WSAIoctl(s, SIO_GET_EXTENSION_FUNCTION_POINTER,
                           &InBuffer, DWORD(MemoryLayout.stride(ofValue: InBuffer)),
                           &pfnWSARecvMsg,
                           DWORD(MemoryLayout.stride(ofValue: pfnWSARecvMsg)),
                           &cbBytesReturned, nil, nil) == SOCKET_ERROR {
            throw IOError(winsock: WSAGetLastError(), reason: "WSAIoctl")
        }

        guard let WSARecvMsg = pfnWSARecvMsg else {
            throw IOError(windows: DWORD(ERROR_INVALID_FUNCTION),
                          reason: "recvmsg")
        }

        var dwNumberOfBytesRecvd: DWORD = 0
        // FIXME(compnerd) is the socket guaranteed to not be overlapped?
        if WSARecvMsg(s, lpMsg, &dwNumberOfBytesRecvd, nil, nil) == SOCKET_ERROR {
            throw IOError(winsock: WSAGetLastError(), reason: "recvmsg")
        }
        return .processed(size_t(dwNumberOfBytesRecvd))
    }

    @inline(never)
    static func sendmsg(socket Handle: NIOBSDSocket.Handle,
                        msgHdr lpMsg: UnsafePointer<msghdr>,
                        flags dwFlags: CInt) throws -> IOResult<size_t> {
        // TODO(compnerd) see comment above
        var InBuffer = WSAID_WSASENDMSG
        var pfnWSASendMsg: LPFN_WSASENDMSG?
        var cbBytesReturned: DWORD = 0
        if WinSDK.WSAIoctl(Handle, SIO_GET_EXTENSION_FUNCTION_POINTER,
                           &InBuffer, DWORD(MemoryLayout.stride(ofValue: InBuffer)),
                           &pfnWSASendMsg,
                           DWORD(MemoryLayout.stride(ofValue: pfnWSASendMsg)),
                           &cbBytesReturned, nil, nil) == SOCKET_ERROR {
            throw IOError(winsock: WSAGetLastError(), reason: "WSAIoctl")
        }

        guard let WSASendMsg = pfnWSASendMsg else {
            throw IOError(windows: DWORD(ERROR_INVALID_FUNCTION),
                          reason: "sendmsg")
        }

        let lpMsg: LPWSAMSG = UnsafeMutablePointer<WSAMSG>(mutating: lpMsg)
        var NumberOfBytesSent: DWORD = 0
        // FIXME(compnerd) is the socket guaranteed to not be overlapped?
        if WSASendMsg(Handle, lpMsg, DWORD(dwFlags), &NumberOfBytesSent, nil,
                      nil) == SOCKET_ERROR {
            throw IOError(winsock: WSAGetLastError(), reason: "sendmsg")
        }
        return .processed(size_t(NumberOfBytesSent))
    }

    @inline(never)
    static func send(socket s: NIOBSDSocket.Handle,
                     buffer buf: UnsafeRawPointer,
                     length len: size_t) throws -> IOResult<size_t> {
        let iResult: CInt = CNIOWindows_send(s, buf, CInt(len), 0)
        if iResult == SOCKET_ERROR {
            throw IOError(winsock: WSAGetLastError(), reason: "send")
        }
        return .processed(size_t(iResult))
    }

    @inline(never)
    static func setsockopt(socket: NIOBSDSocket.Handle,
                           level: NIOBSDSocket.OptionLevel,
                           option_name optname: NIOBSDSocket.Option,
                           option_value optval: UnsafeRawPointer,
                           option_len optlen: socklen_t) throws {
        if CNIOWindows_setsockopt(socket, level.rawValue, optname.rawValue,
                                  optval, optlen) == SOCKET_ERROR {
            throw IOError(winsock: WSAGetLastError(), reason: "setsockopt")
        }
    }

    @inline(never)
    static func shutdown(socket: NIOBSDSocket.Handle, how: Shutdown) throws {
        if WinSDK.shutdown(socket, how.cValue) == SOCKET_ERROR {
            throw IOError(winsock: WSAGetLastError(), reason: "shutdown")
        }
    }

    @inline(never)
    static func socket(domain af: NIOBSDSocket.ProtocolFamily,
                       type: NIOBSDSocket.SocketType,
                       `protocol`: CInt) throws -> NIOBSDSocket.Handle {
        let socket: NIOBSDSocket.Handle = WinSDK.socket(af.rawValue, type.rawValue, `protocol`)
        if socket == WinSDK.INVALID_SOCKET {
            throw IOError(winsock: WSAGetLastError(), reason: "socket")
        }
        return socket
    }

    @inline(never)
    static func recvmmsg(socket: NIOBSDSocket.Handle,
                         msgvec: UnsafeMutablePointer<MMsgHdr>,
                         vlen: CUnsignedInt, flags: CInt,
                         timeout: UnsafeMutablePointer<timespec>?)
            throws -> IOResult<Int> {
        return .processed(Int(CNIOWindows_recvmmsg(socket, msgvec, vlen, flags, timeout)))
    }

    @inline(never)
    static func sendmmsg(socket: NIOBSDSocket.Handle,
                         msgvec: UnsafeMutablePointer<MMsgHdr>,
                         vlen: CUnsignedInt, flags: CInt)
            throws -> IOResult<Int> {
        return .processed(Int(CNIOWindows_sendmmsg(socket, msgvec, vlen, flags)))
    }

    // NOTE: this should return a `ssize_t`, however, that is not a standard
    // type, and defining that type is difficult.  Opt to return a `size_t`
    // which is the same size, but is unsigned.
    @inline(never)
    static func pread(socket: NIOBSDSocket.Handle,
                      pointer: UnsafeMutableRawPointer,
                      size: size_t, offset: off_t) throws -> IOResult<size_t> {
        var ovlOverlapped: OVERLAPPED = OVERLAPPED()
        ovlOverlapped.OffsetHigh = DWORD(UInt32(offset >> 32) & 0xffffffff)
        ovlOverlapped.Offset = DWORD(UInt32(offset >> 0) & 0xffffffff)
        var nNumberOfBytesRead: DWORD = 0
        if !ReadFile(HANDLE(bitPattern: UInt(socket)), pointer, DWORD(size),
                     &nNumberOfBytesRead, &ovlOverlapped) {
            throw IOError(windows: GetLastError(), reason: "ReadFile")
        }
        return .processed(size_t(nNumberOfBytesRead))
    }

    // NOTE: this should return a `ssize_t`, however, that is not a standard
    // type, and defining that type is difficult.  Opt to return a `size_t`
    // which is the same size, but is unsigned.
    @inline(never)
    static func pwrite(socket: NIOBSDSocket.Handle, pointer: UnsafeRawPointer,
                       size: size_t, offset: off_t) throws -> IOResult<size_t> {
        var ovlOverlapped: OVERLAPPED = OVERLAPPED()
        ovlOverlapped.OffsetHigh = DWORD(UInt32(offset >> 32) & 0xffffffff)
        ovlOverlapped.Offset = DWORD(UInt32(offset >> 0) & 0xffffffff)
        var nNumberOfBytesWritten: DWORD = 0
        if !WriteFile(HANDLE(bitPattern: UInt(socket)), pointer, DWORD(size),
                      &nNumberOfBytesWritten, &ovlOverlapped) {
            throw IOError(windows: GetLastError(), reason: "WriteFile")
        }
        return .processed(size_t(nNumberOfBytesWritten))
    }

    @inline(never)
    static func sendfile(socket s: NIOBSDSocket.Handle, fd: CInt, offset: off_t,
                         len nNumberOfBytesToWrite: off_t)
            throws -> IOResult<Int> {
        let hFile: HANDLE = HANDLE(bitPattern: ucrt._get_osfhandle(fd))!
        if hFile == INVALID_HANDLE_VALUE {
            throw IOError(errnoCode: EBADF, reason: "_get_osfhandle")
        }

        var ovlOverlapped: OVERLAPPED = OVERLAPPED()
        ovlOverlapped.Offset = DWORD(UInt32(offset >> 0) & 0xffffffff)
        ovlOverlapped.OffsetHigh = DWORD(UInt32(offset >> 32) & 0xffffffff)
        if !TransmitFile(s, hFile, DWORD(nNumberOfBytesToWrite), 0,
                         &ovlOverlapped, nil, DWORD(TF_USE_KERNEL_APC)) {
            throw IOError(winsock: WSAGetLastError(), reason: "TransmitFile")
        }

        return .processed(Int(nNumberOfBytesToWrite))
    }
}

extension NIOBSDSocket {
    @inline(never)
    static func setNonBlocking(socket: NIOBSDSocket.Handle) throws {
        var ulMode: u_long = 1
        if WinSDK.ioctlsocket(socket, FIONBIO, &ulMode) == SOCKET_ERROR {
            let iResult = WSAGetLastError()
            if iResult == WSAEINVAL {
                throw NIOFcntlFailedError()
            }
            throw IOError(winsock: WSAGetLastError(), reason: "ioctlsocket")
        }
    }

    static func cleanupUnixDomainSocket(atPath path: String) throws {
        guard let hFile = (path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, GENERIC_READ,
                        DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                        nil, DWORD(OPEN_EXISTING),
                        DWORD(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS),
                        nil)
        }) else {
            throw IOError(windows: DWORD(EBADF), reason: "CreateFileW")
        }
        defer { CloseHandle(hFile) }

        let ftFileType =  GetFileType(hFile)
        let dwError = GetLastError()
        guard dwError == NO_ERROR, ftFileType != FILE_TYPE_DISK else {
            throw IOError(windows: dwError, reason: "GetFileType")
        }

        var fiInformation: BY_HANDLE_FILE_INFORMATION =
                BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(hFile, &fiInformation) else {
            throw IOError(windows: GetLastError(), reason: "GetFileInformationByHandle")
        }

        guard fiInformation.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == FILE_ATTRIBUTE_REPARSE_POINT else {
            throw UnixDomainSocketPathWrongType()
        }

        var nBytesWritten: DWORD = 0
        var dbReparseDataBuffer: CNIOWindows_REPARSE_DATA_BUFFER =
            CNIOWindows_REPARSE_DATA_BUFFER()
        try withUnsafeMutablePointer(to: &dbReparseDataBuffer) {
            if !DeviceIoControl(hFile, FSCTL_GET_REPARSE_POINT, nil, 0, $0,
                                DWORD(MemoryLayout<CNIOWindows_REPARSE_DATA_BUFFER>.stride),
                                &nBytesWritten, nil) {
                throw IOError(windows: GetLastError(), reason: "DeviceIoControl")
            }
        }

        guard dbReparseDataBuffer.ReparseTag == IO_REPARSE_TAG_AF_UNIX else {
            throw UnixDomainSocketPathWrongType()
        }

        var fdi: FILE_DISPOSITION_INFO_EX = FILE_DISPOSITION_INFO_EX()
        fdi.Flags = DWORD(FILE_DISPOSITION_FLAG_DELETE | FILE_DISPOSITION_FLAG_POSIX_SEMANTICS)

        if !SetFileInformationByHandle(hFile, FileDispositionInfoEx, &fdi,
                                       DWORD(MemoryLayout<FILE_DISPOSITION_INFO_EX>.stride)) {
            throw IOError(windows: GetLastError(), reason: "GetFileInformationByHandle")
        }
    }
}

// MARK: _BSDSocketControlMessageProtocol implementation
extension NIOBSDSocketControlMessage {
    static func firstHeader(inside msghdr: UnsafePointer<msghdr>)
            -> UnsafeMutablePointer<cmsghdr>? {
        return CNIOWindows_CMSG_FIRSTHDR(msghdr)
    }

    static func nextHeader(inside msghdr: UnsafeMutablePointer<msghdr>,
                           after: UnsafeMutablePointer<cmsghdr>)
            -> UnsafeMutablePointer<cmsghdr>? {
        return CNIOWindows_CMSG_NXTHDR(msghdr, after)
    }

    static func data(for header: UnsafePointer<cmsghdr>)
            -> UnsafeRawBufferPointer? {
        let data = CNIOWindows_CMSG_DATA(header)
        let length =
            size_t(header.pointee.cmsg_len) - NIOBSDSocketControlMessage.length(payloadSize: 0)
        return UnsafeRawBufferPointer(start: data, count: Int(length))
    }

    static func data(for header: UnsafeMutablePointer<cmsghdr>)
            -> UnsafeMutableRawBufferPointer? {
        let data = CNIOWindows_CMSG_DATA_MUTABLE(header)
        let length =
            size_t(header.pointee.cmsg_len) - NIOBSDSocketControlMessage.length(payloadSize: 0)
        return UnsafeMutableRawBufferPointer(start: data, count: Int(length))
    }

    static func length(payloadSize: size_t) -> size_t {
        return CNIOWindows_CMSG_LEN(payloadSize)
    }

    static func space(payloadSize: size_t) -> size_t {
        return CNIOWindows_CMSG_SPACE(payloadSize)
    }
}
#endif
