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
    let sysSocket = Darwin.socket
    let sysSOCK_STREAM = SOCK_STREAM
#elseif os(Linux)
    import Glibc
    let sysAccept = Glibc.accept
    let sysListen = Glibc.listen
    let sysSocket = Glibc.socket
    let sysSOCK_STREAM = SOCK_STREAM.rawValue
#endif


// TODO: Handle AF_INET6 as well
public class ServerSocket: BaseSocket {
    
    public class func bootstrap(host: String, port: Int32) throws -> ServerSocket {
        let socket = try ServerSocket();
        try socket.bind(address: SocketAddresses.newAddress(for: host, on: port)!)
        try socket.listen()
        return socket
    }
    
    public init() throws {
        let fd = sysSocket(AF_INET, Int32(sysSOCK_STREAM), 0)
        if fd < 0 {
            throw ioError(errno: errno, function: "socket")
        }
        super.init(descriptor: fd)
    }
    
    public func listen(backlog: Int32 = 128) throws {
        let res = sysListen(self.descriptor, backlog)
        guard res >= 0 else {
            throw ioError(errno: errno, function: "listen")
        }
    }
    
    public func accept() throws -> Socket? {
        var acceptAddr = sockaddr_in()
        var addrSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        
        while true {
            let fd = withUnsafeMutablePointer(to: &acceptAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    sysAccept(self.descriptor, ptr, &addrSize)
                }
            }
        
            guard fd >= 0 else {
                let err = errno
                if (err == EINTR) {
                    continue
                }
                guard err == EWOULDBLOCK else {
                    throw ioError(errno: errno, function: "accept")
                }
                return nil
            }
    
#if os(Linux)
            /* no SO_NOSIGPIPE on Linux :( */
            let old_sighandler = signal(SIGPIPE, SIG_IGN);
            if old_sighandler == SIG_ERR {
                return nil
            }
#else
            // TODO: Handle return code ?
            let _ = Darwin.fcntl(fd, F_SETNOSIGPIPE, 1);
#endif

            return Socket(descriptor: fd)
        }
    }
}
