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

final class SelectablePipeHandle {
    var fileDescriptor: CInt

    var isOpen: Bool {
        self.fileDescriptor >= 0
    }

    init(takingOwnershipOfDescriptor fd: CInt) {
        precondition(fd >= 0)
        self.fileDescriptor = fd
    }

    func close() throws {
        let fd = try self.takeDescriptorOwnership()
        try Posix.close(descriptor: fd)
    }

    func takeDescriptorOwnership() throws -> CInt {
        guard self.isOpen else {
            throw IOError(errnoCode: EBADF, reason: "SelectablePipeHandle already closed [in close]")
        }
        defer {
            self.fileDescriptor = -1
        }
        return self.fileDescriptor
    }

    deinit {
        assert(!self.isOpen, "leaking \(self)")
    }
}

extension SelectablePipeHandle: Selectable {
    func withUnsafeHandle<T>(_ body: (CInt) throws -> T) throws -> T {
        guard self.isOpen else {
            throw IOError(errnoCode: EBADF, reason: "SelectablePipeHandle already closed [in wUH]")
        }
        return try body(self.fileDescriptor)
    }
}

extension SelectablePipeHandle: CustomStringConvertible {
    public var description: String {
        "SelectableFileHandle(isOpen: \(self.isOpen), fd: \(self.fileDescriptor))"
    }
}

final class PipePair: SocketProtocol {
    typealias SelectableType = SelectablePipeHandle

    let input: SelectablePipeHandle?
    let output: SelectablePipeHandle?

    init(input: SelectablePipeHandle?, output: SelectablePipeHandle?) throws {
        self.input = input
        self.output = output
        try self.ignoreSIGPIPE()
        for fh in [input, output].compactMap({ $0 }) {
            try fh.withUnsafeHandle { fd in
                try NIOFileHandle.setNonBlocking(fileDescriptor: fd)
            }
        }
    }

    func ignoreSIGPIPE() throws {
        for fileHandle in [self.input, self.output].compactMap({ $0 }) {
            try fileHandle.withUnsafeHandle {
                try PipePair.ignoreSIGPIPE(descriptor: $0)
            }
        }
    }

    var description: String {
        "PipePair { in=\(String(describing: self.input)), out=\(String(describing: self.output)) }"
    }

    func connect(to address: SocketAddress) throws -> Bool {
        throw ChannelError._operationUnsupported
    }

    func finishConnect() throws {
        throw ChannelError._operationUnsupported
    }

    func write(pointer: UnsafeRawBufferPointer) throws -> IOResult<Int> {
        guard let outputSPH = self.output else {
            fatalError("Internal inconsistency inside NIO: outputSPH closed on write. Please file a bug")
        }
        return try outputSPH.withUnsafeHandle {
            try Posix.write(descriptor: $0, pointer: pointer.baseAddress!, size: pointer.count)
        }
    }

    func writev(iovecs: UnsafeBufferPointer<IOVector>) throws -> IOResult<Int> {
        guard let outputSPH = self.output else {
            fatalError("Internal inconsistency inside NIO: outputSPH closed on writev. Please file a bug")
        }
        return try outputSPH.withUnsafeHandle {
            try Posix.writev(descriptor: $0, iovecs: iovecs)
        }
    }

    func read(pointer: UnsafeMutableRawBufferPointer) throws -> IOResult<Int> {
        guard let inputSPH = self.input else {
            fatalError("Internal inconsistency inside NIO: inputSPH closed on read. Please file a bug")
        }
        return try inputSPH.withUnsafeHandle {
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
            try self.input?.close()
        case .WR:
            try self.output?.close()
        case .RDWR:
            try self.close()
        }
    }

    var isOpen: Bool {
        self.input?.isOpen ?? false || self.output?.isOpen ?? false
    }

    func close() throws {
        guard self.isOpen else {
            throw ChannelError._alreadyClosed
        }
        let r1 = Result {
            if let inputFD = self.input, inputFD.isOpen {
                try inputFD.close()
            }
        }
        let r2 = Result {
            if let outputFD = self.output, outputFD.isOpen {
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
