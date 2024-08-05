//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIOCore

struct SelectableFileHandle {
    var handle: NIOFileHandle

    var isOpen: Bool {
        handle.isOpen
    }

    init(_ handle: NIOFileHandle) {
        self.handle = handle
    }

    func close() throws {
        try handle.close()
    }
}

extension SelectableFileHandle: Selectable {
    func withUnsafeHandle<T>(_ body: (CInt) throws -> T) throws -> T {
        try self.handle.withUnsafeFileDescriptor(body)
    }
}

final class PipePair: SocketProtocol {
    typealias SelectableType = SelectableFileHandle

    let inputFD: SelectableFileHandle?
    let outputFD: SelectableFileHandle?

    init(inputFD: NIOFileHandle?, outputFD: NIOFileHandle?) throws {
        self.inputFD = inputFD.flatMap { SelectableFileHandle($0) }
        self.outputFD = outputFD.flatMap { SelectableFileHandle($0) }
        try self.ignoreSIGPIPE()
        for fileHandle in [inputFD, outputFD].compactMap({ $0 }) {
            try fileHandle.withUnsafeFileDescriptor {
                try NIOFileHandle.setNonBlocking(fileDescriptor: $0)
            }
        }
    }

    func ignoreSIGPIPE() throws {
        for fileHandle in [self.inputFD, self.outputFD].compactMap({ $0 }) {
            try fileHandle.withUnsafeHandle {
                try PipePair.ignoreSIGPIPE(descriptor: $0)
            }
        }
    }

    var description: String {
        "PipePair { in=\(String(describing: inputFD)), out=\(String(describing: inputFD)) }"
    }

    func connect(to address: SocketAddress) throws -> Bool {
        throw ChannelError._operationUnsupported
    }

    func finishConnect() throws {
        throw ChannelError._operationUnsupported
    }

    func write(pointer: UnsafeRawBufferPointer) throws -> IOResult<Int> {
        guard let outputFD = self.outputFD else {
            fatalError("Internal inconsistency inside NIO. Please file a bug")
        }
        return try outputFD.withUnsafeHandle {
            try Posix.write(descriptor: $0, pointer: pointer.baseAddress!, size: pointer.count)
        }
    }

    func writev(iovecs: UnsafeBufferPointer<IOVector>) throws -> IOResult<Int> {
        guard let outputFD = self.outputFD else {
            fatalError("Internal inconsistency inside NIO. Please file a bug")
        }
        return try outputFD.withUnsafeHandle {
            try Posix.writev(descriptor: $0, iovecs: iovecs)
        }
    }

    func read(pointer: UnsafeMutableRawBufferPointer) throws -> IOResult<Int> {
        guard let inputFD = self.inputFD else {
            fatalError("Internal inconsistency inside NIO. Please file a bug")
        }
        return try inputFD.withUnsafeHandle {
            try Posix.read(descriptor: $0, pointer: pointer.baseAddress!, size: pointer.count)
        }
    }

    func recvmsg(
        pointer: UnsafeMutableRawBufferPointer,
        storage: inout sockaddr_storage,
        storageLen: inout socklen_t,
        controlBytes: inout UnsafeReceivedControlBytes
    ) throws -> IOResult<Int> {
        throw ChannelError._operationUnsupported
    }

    func sendmsg(
        pointer: UnsafeRawBufferPointer,
        destinationPtr: UnsafePointer<sockaddr>?,
        destinationSize: socklen_t,
        controlBytes: UnsafeMutableRawBufferPointer
    ) throws -> IOResult<Int> {
        throw ChannelError._operationUnsupported
    }

    func sendFile(fd: CInt, offset: Int, count: Int) throws -> IOResult<Int> {
        throw ChannelError._operationUnsupported
    }

    func recvmmsg(msgs: UnsafeMutableBufferPointer<MMsgHdr>) throws -> IOResult<Int> {
        throw ChannelError._operationUnsupported
    }

    func sendmmsg(msgs: UnsafeMutableBufferPointer<MMsgHdr>) throws -> IOResult<Int> {
        throw ChannelError._operationUnsupported
    }

    func shutdown(how: Shutdown) throws {
        switch how {
        case .RD:
            try self.inputFD?.close()
        case .WR:
            try self.outputFD?.close()
        case .RDWR:
            try self.close()
        }
    }

    var isOpen: Bool {
        self.inputFD?.isOpen ?? false || self.outputFD?.isOpen ?? false
    }

    func close() throws {
        guard self.isOpen else {
            throw ChannelError._alreadyClosed
        }
        let r1 = Result {
            if let inputFD = self.inputFD, inputFD.isOpen {
                try inputFD.close()
            }
        }
        let r2 = Result {
            if let outputFD = self.outputFD, outputFD.isOpen {
                try outputFD.close()
            }
        }
        try r1.get()
        try r2.get()
    }

    func bind(to address: SocketAddress) throws {
        throw ChannelError._operationUnsupported
    }

    func localAddress() throws -> SocketAddress {
        throw ChannelError._operationUnsupported
    }

    func remoteAddress() throws -> SocketAddress {
        throw ChannelError._operationUnsupported
    }

    func setOption<T>(level: NIOBSDSocket.OptionLevel, name: NIOBSDSocket.Option, value: T) throws {
        throw ChannelError._operationUnsupported
    }

    func getOption<T>(level: NIOBSDSocket.OptionLevel, name: NIOBSDSocket.Option) throws -> T {
        throw ChannelError._operationUnsupported
    }
}
