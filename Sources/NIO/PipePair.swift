//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

struct SelectableFileHandle {
    var handle: NIOFileHandle

    var isOpen: Bool {
        self.handle.isOpen
    }

    init(_ handle: NIOFileHandle) {
        self.handle = handle
    }

    func close() throws {
        try self.handle.close()
    }
}

extension SelectableFileHandle: Selectable {
    func withUnsafeHandle<T>(_ body: (CInt) throws -> T) throws -> T {
        try self.handle.withUnsafeFileDescriptor(body)
    }
}

final class PipePair: SocketProtocol {
    typealias SelectableType = SelectableFileHandle

    let inputFD: SelectableFileHandle
    let outputFD: SelectableFileHandle

    init(inputFD: NIOFileHandle, outputFD: NIOFileHandle) throws {
        self.inputFD = SelectableFileHandle(inputFD)
        self.outputFD = SelectableFileHandle(outputFD)
        try self.ignoreSIGPIPE()
        for fileHandle in [inputFD, outputFD] {
            try fileHandle.withUnsafeFileDescriptor {
                try NIOFileHandle.setNonBlocking(fileDescriptor: $0)
            }
        }
    }

    func ignoreSIGPIPE() throws {
        for fileHandle in [self.inputFD, self.outputFD] {
            try fileHandle.withUnsafeHandle {
                try PipePair.ignoreSIGPIPE(descriptor: $0)
            }
        }
    }

    var description: String {
        "PipePair { in=\(self.inputFD), out=\(self.outputFD) }"
    }

    func connect(to _: SocketAddress) throws -> Bool {
        throw ChannelError.operationUnsupported
    }

    func finishConnect() throws {
        throw ChannelError.operationUnsupported
    }

    func write(pointer: UnsafeRawBufferPointer) throws -> IOResult<Int> {
        try self.outputFD.withUnsafeHandle {
            try Posix.write(descriptor: $0, pointer: pointer.baseAddress!, size: pointer.count)
        }
    }

    func writev(iovecs: UnsafeBufferPointer<IOVector>) throws -> IOResult<Int> {
        try self.outputFD.withUnsafeHandle {
            try Posix.writev(descriptor: $0, iovecs: iovecs)
        }
    }

    func read(pointer: UnsafeMutableRawBufferPointer) throws -> IOResult<Int> {
        try self.inputFD.withUnsafeHandle {
            try Posix.read(descriptor: $0, pointer: pointer.baseAddress!, size: pointer.count)
        }
    }

    func recvmsg(pointer _: UnsafeMutableRawBufferPointer,
                 storage _: inout sockaddr_storage,
                 storageLen _: inout socklen_t,
                 controlBytes _: inout UnsafeReceivedControlBytes) throws -> IOResult<Int>
    {
        throw ChannelError.operationUnsupported
    }

    func sendmsg(pointer _: UnsafeRawBufferPointer,
                 destinationPtr _: UnsafePointer<sockaddr>,
                 destinationSize _: socklen_t,
                 controlBytes _: UnsafeMutableRawBufferPointer) throws -> IOResult<Int>
    {
        throw ChannelError.operationUnsupported
    }

    func sendFile(fd _: CInt, offset _: Int, count _: Int) throws -> IOResult<Int> {
        throw ChannelError.operationUnsupported
    }

    func recvmmsg(msgs _: UnsafeMutableBufferPointer<MMsgHdr>) throws -> IOResult<Int> {
        throw ChannelError.operationUnsupported
    }

    func sendmmsg(msgs _: UnsafeMutableBufferPointer<MMsgHdr>) throws -> IOResult<Int> {
        throw ChannelError.operationUnsupported
    }

    func shutdown(how: Shutdown) throws {
        switch how {
        case .RD:
            try self.inputFD.close()
        case .WR:
            try self.outputFD.close()
        case .RDWR:
            try self.close()
        }
    }

    var isOpen: Bool {
        self.inputFD.isOpen || self.outputFD.isOpen
    }

    func close() throws {
        guard self.inputFD.isOpen || self.outputFD.isOpen else {
            throw ChannelError.alreadyClosed
        }
        let r1 = Result {
            if self.inputFD.isOpen {
                try self.inputFD.close()
            }
        }
        let r2 = Result {
            if self.outputFD.isOpen {
                try self.outputFD.close()
            }
        }
        try r1.get()
        try r2.get()
    }

    func bind(to _: SocketAddress) throws {
        throw ChannelError.operationUnsupported
    }

    func localAddress() throws -> SocketAddress {
        throw ChannelError.operationUnsupported
    }

    func remoteAddress() throws -> SocketAddress {
        throw ChannelError.operationUnsupported
    }

    func setOption<T>(level _: NIOBSDSocket.OptionLevel, name _: NIOBSDSocket.Option, value _: T) throws {
        throw ChannelError.operationUnsupported
    }

    func getOption<T>(level _: NIOBSDSocket.OptionLevel, name _: NIOBSDSocket.Option) throws -> T {
        throw ChannelError.operationUnsupported
    }
}
