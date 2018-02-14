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

public typealias IOVector = iovec

// TODO: scattering support
final class Socket : BaseSocket {
    static var writevLimitBytes: Int {
        return Int(Int32.max)
    }
    static let writevLimitIOVectors: Int = Posix.UIO_MAXIOV

    init(protocolFamily: CInt, type: CInt) throws {
        let sock = try BaseSocket.newSocket(protocolFamily: protocolFamily, type: type)
        super.init(descriptor: sock)
    }
    
    override init(descriptor : Int32) {
        super.init(descriptor: descriptor)
    }
    
    func connect(to address: SocketAddress) throws -> Bool {
        switch address {
        case .v4(let addr):
            return try connectSocket(addr: addr.address)
        case .v6(let addr):
            return try connectSocket(addr: addr.address)
        case .unixDomainSocket(let addr):
            return try connectSocket(addr: addr.address)
        }
    }
    
    private func connectSocket<T>(addr: T) throws -> Bool {
        guard self.open else {
            throw IOError(errnoCode: EBADF, reason: "can't connect socket as it's not open anymore.")
        }
        var addr = addr
        return try withUnsafePointer(to: &addr) { ptr in
            try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                try Posix.connect(descriptor: self.descriptor, addr: ptr, size: socklen_t(MemoryLayout<T>.size))
            }
        }
    }
    
    func finishConnect() throws {
        let result: Int32 = try getOption(level: SOL_SOCKET, name: SO_ERROR)
        if result != 0 {
            throw IOError(errnoCode: result, function: "getsockopt")
        }
    }
    
    func write(pointer: UnsafePointer<UInt8>, size: Int) throws -> IOResult<Int> {
        guard self.open else {
            throw IOError(errnoCode: EBADF, reason: "can't write to socket as it's not open anymore.")
        }
        return try Posix.write(descriptor: self.descriptor, pointer: pointer, size: size)
    }

    func writev(iovecs: UnsafeBufferPointer<IOVector>) throws -> IOResult<Int> {
        guard self.open else {
            throw IOError(errnoCode: EBADF, reason: "can't writev to socket as it's not open anymore.")
        }

        return try Posix.writev(descriptor: self.descriptor, iovecs: iovecs)
    }

    func sendto(pointer: UnsafePointer<UInt8>, size: Int, destinationPtr: UnsafePointer<sockaddr>, destinationSize: socklen_t) throws -> IOResult<Int> {
        guard self.open else {
            throw IOError(errnoCode: EBADF, reason: "can't sendto to socket as it's not open anymore.")
        }

        return try Posix.sendto(descriptor: self.descriptor, pointer: UnsafeMutablePointer(mutating: pointer), size: size, destinationPtr: destinationPtr, destinationSize: destinationSize)
    }
    
    func read(pointer: UnsafeMutablePointer<UInt8>, size: Int) throws -> IOResult<Int> {
        guard self.open else {
            throw IOError(errnoCode: EBADF, reason: "can't read from socket as it's not open anymore.")
        }

        return try Posix.read(descriptor: self.descriptor, pointer: pointer, size: size)
    }

    func recvfrom(pointer: UnsafeMutablePointer<UInt8>, size: Int, storage: inout sockaddr_storage, storageLen: inout socklen_t) throws -> IOResult<(Int)> {
        guard self.open else {
            throw IOError(errnoCode: EBADF, reason: "can't recvfrom socket as it's not open anymore")
        }

        return try storage.withMutableSockAddr { (storagePtr, _) in
            try Posix.recvfrom(descriptor: self.descriptor, pointer: pointer, len: size, addr: storagePtr, addrlen: &storageLen)
        }
    }
    
    func sendFile(fd: Int32, offset: Int, count: Int) throws -> IOResult<Int> {
        guard self.open else {
            throw IOError(errnoCode: EBADF, reason: "can't write to socket as it's not open anymore.")
        }
      
        return try Posix.sendfile(descriptor: self.descriptor, fd: fd, offset: off_t(offset), count: count)
    }

    func recvmmsg(msgs: UnsafeMutableBufferPointer<MMsgHdr>) throws -> IOResult<Int> {
        guard self.open else {
            throw IOError(errnoCode: EBADF, reason: "can't read from socket as it's not open anymore.")
        }

        return try Posix.recvmmsg(sockfd: self.descriptor, msgvec: msgs.baseAddress!, vlen: CUnsignedInt(msgs.count), flags: 0, timeout: nil)
    }

    func sendmmsg(msgs: UnsafeMutableBufferPointer<MMsgHdr>) throws -> IOResult<Int> {
        guard self.open else {
            throw IOError(errnoCode: EBADF, reason: "can't write to socket as it's not open anymore.")
        }

        return try Posix.sendmmsg(sockfd: self.descriptor, msgvec: msgs.baseAddress!, vlen: CUnsignedInt(msgs.count), flags: 0)
    }
    
    func shutdown(how: Shutdown) throws {
        guard self.open else {
            throw IOError(errnoCode: EBADF, reason: "can't shutdown socket as it's not open anymore.")
        }
        try Posix.shutdown(descriptor: self.descriptor, how: how)
    }
}
