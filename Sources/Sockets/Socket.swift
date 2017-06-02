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


// TODO: scattering support
public class Socket : BaseSocket {
    
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
    
    public func write(data: Data) throws -> Int? {
        return try data.withUnsafeBytes({ try write(pointer: $0, size: data.count) })
    }

    public func write(pointer: UnsafePointer<UInt8>, size: Int) throws -> Int? {
        return try wrapSyscallMayBlock({ $0 >= 0 }, function: "write") {
            sysWrite(self.descriptor, pointer, size)
        }
    }

    public func writev(datas: Data... ) throws -> Int? {
        var iovecs: [iovec] = []

        // This is a bit messy as there is not other way at the moment to ensure the pointers are not "freed" before we were able to do the syscall.
        // To ensure we not get into trouble because of stackoverflow we use a limit of 1024 recursive calls for now.
        func writev0(index: Int) throws -> Int? {
            if datas.count == iovecs.count || iovecs.count == Socket.writevLimit {
                return try wrapSyscallMayBlock({ $0 >= 0 }, function: "writev") {
                    sysWritev(self.descriptor, iovecs, Int32(iovecs.count))
                }
            }
            let data = datas[index]
            return try data.withUnsafeBytes { (pointer: UnsafePointer<UInt8>) -> Int? in
                iovecs.append(iovec(iov_base: UnsafeMutableRawPointer(mutating: pointer), iov_len: data.count))
                return try writev0(index: index + 1)
            }
        }

        return try writev0(index: 0)
    }
    
    
    public func writev(pointers: [(UnsafePointer<UInt8>, Int)]) throws -> Int? {
        let iovecs = pointers.map { ptr in iovec(iov_base: UnsafeMutableRawPointer(mutating: ptr.0), iov_len: ptr.1) }

        return try wrapSyscallMayBlock({ $0 >= 0 }, function: "writev") {
            sysWritev(self.descriptor, iovecs, Int32(iovecs.count))
        }
    }
    
    public func read(data: inout Data) throws -> Int? {
        return try data.withUnsafeMutableBytes({ try read(pointer: $0, size: data.count) })
    }

    public func read(pointer: UnsafeMutablePointer<UInt8>, size: Int) throws -> Int? {
        return try wrapSyscallMayBlock({ $0 >= 0 }, function: "read") {
            sysRead(self.descriptor, pointer, size)
        }
    }
}
