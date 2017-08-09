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

import Foundation


#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    import Darwin
    let sysAccept = Darwin.accept
    let sysListen = Darwin.listen
#elseif os(Linux)
    import Glibc
    let sysAccept = Glibc.accept
    let sysListen = Glibc.listen
#endif


// TODO: Handle AF_INET6 as well
final class ServerSocket: BaseSocket {
    public class func bootstrap(protocolFamily: Int32, host: String, port: Int32) throws -> ServerSocket {
        let socket = try ServerSocket(protocolFamily: protocolFamily)
        try socket.bind(to: SocketAddress.newAddressResolving(host: host, port: port))
        try socket.listen()
        return socket
    }
    
    init(protocolFamily: Int32) throws {
        let sock = try BaseSocket.newSocket(protocolFamily: protocolFamily)
        super.init(descriptor: sock)
    }
    
    func listen(backlog: Int32 = 128) throws {
        #if os(Linux)
            /* no SO_NOSIGPIPE on Linux :( */
            _ = try wrapSyscall({ $0 != unsafeBitCast(SIG_ERR, to: Int.self) }, function: "signal") {
                unsafeBitCast(Glibc.signal(SIGPIPE, SIG_IGN) as sighandler_t?, to: Int.self)
            }
        #endif

        _ = try wrapSyscall({ $0 >= 0 }, function: "listen") { () -> Int32 in
            sysListen(self.descriptor, backlog)
        }
    }
    
    func accept() throws -> Socket? {
        var acceptAddr = sockaddr_in()
        var addrSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        
        let ret = try withUnsafeMutablePointer(to: &acceptAddr) { ptr in
            try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                try wrapSyscallMayBlock({ $0 >= 0 }, function: "accept") {
                    sysAccept(self.descriptor, ptr, &addrSize)
                }
            }
        }
        
        switch ret {
        case .wouldBlock:
            return nil
        case .processed(let fd):
            #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
                // TODO: Handle return code ?
                _ = try wrapSyscall({ $0 != -1 }, function: "fcntl") {
                    Darwin.fcntl(fd, F_SETNOSIGPIPE, 1);
                }
            #endif
        
            return Socket(descriptor: fd)
        }
    }
}
