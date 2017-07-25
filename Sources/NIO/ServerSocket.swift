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
            #if os(Linux)
                /* no SO_NOSIGPIPE on Linux :( */
                let old_sighandler: sighandler_t = Glibc.signal(SIGPIPE, SIG_IGN)

                let old_sighandler_ptr = unsafeBitCast(old_sighandler, to: UnsafeRawPointer.self)
                let sig_err_ptr = unsafeBitCast(SIG_ERR, to: UnsafeRawPointer.self)

                if old_sighandler_ptr == sig_err_ptr {
                    return nil
                }
            #else
                // TODO: Handle return code ?
                _ = Darwin.fcntl(fd, F_SETNOSIGPIPE, 1);
            #endif
        
            return Socket(descriptor: fd)
        }
    }
}
