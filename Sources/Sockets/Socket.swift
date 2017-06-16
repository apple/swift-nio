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


#if os(Linux)
import Glibc
let sysWrite = Glibc.write
let sysWritev = Glibc.writev
let sysRead = Glibc.read
let sysConnect = Glibc.connect

#else
import Darwin
let sysWrite = Darwin.write
let sysWritev = Darwin.writev
let sysRead = Darwin.read
let sysConnect = Darwin.connect
#endif

public typealias IOVector = iovec

// TODO: scattering support
public final class Socket : BaseSocket {
    
    public static var writevLimit: Int {
// UIO_MAXIOV is only exported on linux atm
#if os(Linux)
            return Int(UIO_MAXIOV)
#else
            return 1024
#endif
    }
    
    public init() throws {
        let sock = try BaseSocket.newSocket()
        super.init(descriptor: sock)
    }
    
    override init(descriptor : Int32) {
        super.init(descriptor: descriptor)
    }
    
    public func connect(remote: SocketAddress) throws  -> Bool {
        switch remote {
        case .v4(address: let addr):
            return try connectSocket(addr: addr)
        case .v6(address: let addr):
            return try connectSocket(addr: addr)
        }
    }
    
    private func connectSocket<T>(addr: T) throws -> Bool {
        guard self.open else {
            throw IOError(errno: EBADF, reason: "can't connect socket as it's not open anymore.")
        }
        var addr = addr
        return try withUnsafePointer(to: &addr) { (ptr: UnsafePointer<T>) -> Bool in
            try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                do {
                    let _ = try wrapSyscall({ $0 != -1 }, function: "connect") {
                        sysConnect(self.descriptor, ptr, socklen_t(MemoryLayout.size(ofValue: addr)))
                    }
                    return true
                } catch let err as IOError {
                    if err.errno == EINPROGRESS {
                        return false
                    }
                    throw err
                }
            }
        }
    }
    
    public func finishConnect() throws {
        let result: Int32 = try getOption(level: SOL_SOCKET, name: SO_ERROR)
        if result != 0 {
            throw ioError(errno: result, function: "getsockopt")
        }
    }
    
    public func write(data: Data) throws -> IOResult<Int> {
        return try data.withUnsafeBytes({ try write(pointer: $0, size: data.count) })
    }

    public func write(pointer: UnsafePointer<UInt8>, size: Int) throws -> IOResult<Int> {
        guard self.open else {
            throw IOError(errno: EBADF, reason: "can't write to socket as it's not open anymore.")
        }
        return try wrapSyscallMayBlock({ $0 >= 0 }, function: "write") {
            sysWrite(self.descriptor, pointer, size)
        }
    }

    public func writev(iovecs: UnsafeBufferPointer<IOVector>) throws -> IOResult<Int> {
        guard self.open else {
            throw IOError(errno: EBADF, reason: "can't writev to socket as it's not open anymore.")
        }

        return try wrapSyscallMayBlock({ $0 >= 0 }, function: "writev") {
            sysWritev(self.descriptor, iovecs.baseAddress!, Int32(iovecs.count))
        }
    }
    
    public func read(data: inout Data) throws -> IOResult<Int> {
        return try data.withUnsafeMutableBytes({ try read(pointer: $0, size: data.count) })
    }

    public func read(pointer: UnsafeMutablePointer<UInt8>, size: Int) throws -> IOResult<Int> {
        guard self.open else {
            throw IOError(errno: EBADF, reason: "can't read from socket as it's not open anymore.")
        }

        return try wrapSyscallMayBlock({ $0 >= 0 }, function: "read") {
            sysRead(self.descriptor, pointer, size)
        }
    }
}
