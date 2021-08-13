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

final class PipeChannel: BaseStreamSocketChannel<PipePair> {
    private let pipePair: PipePair

    internal enum Direction {
        case input
        case output
    }

    init(eventLoop: SelectableEventLoop,
         inputPipe: NIOFileHandle,
         outputPipe: NIOFileHandle) throws {
        self.pipePair = try PipePair(inputFD: inputPipe, outputFD: outputPipe)
        try super.init(socket: self.pipePair,
                       parent: nil,
                       eventLoop: eventLoop,
                       recvAllocator: AdaptiveRecvByteBufferAllocator())
    }

    func registrationForInput(interested: SelectorEventSet, registrationID: SelectorRegistrationID) -> NIORegistration {
        return NIORegistration(channel: .pipeChannel(self, .input),
                               interested: interested,
                               registrationID: registrationID)
    }

    func registrationForOutput(interested: SelectorEventSet, registrationID: SelectorRegistrationID) -> NIORegistration {
        return NIORegistration(channel: .pipeChannel(self, .output),
                               interested: interested,
                               registrationID: registrationID)
    }

    override func connectSocket(to address: SocketAddress) throws -> Bool {
        throw ChannelError.operationUnsupported
    }

    override func finishConnectSocket() throws {
        throw ChannelError.inappropriateOperationForState
    }

    override func register(selector: Selector<NIORegistration>, interested: SelectorEventSet) throws {
        try selector.register(selectable: self.pipePair.inputFD,
                              interested: interested.intersection([.read, .reset]),
                              makeRegistration: self.registrationForInput)
        try selector.register(selectable: self.pipePair.outputFD,
                              interested: interested.intersection([.write, .reset]),
                              makeRegistration: self.registrationForOutput)

    }

    override func deregister(selector: Selector<NIORegistration>, mode: CloseMode) throws {
        if (mode == .all || mode == .input) && self.pipePair.inputFD.isOpen {
            try selector.deregister(selectable: self.pipePair.inputFD)
        }
        if (mode == .all || mode == .output) && self.pipePair.outputFD.isOpen {
            try selector.deregister(selectable: self.pipePair.outputFD)
        }
    }

    override func reregister(selector: Selector<NIORegistration>, interested: SelectorEventSet) throws {
        if self.pipePair.inputFD.isOpen {
            try selector.reregister(selectable: self.pipePair.inputFD,
                                    interested: interested.intersection([.read, .reset]))
        }
        if self.pipePair.outputFD.isOpen {
            try selector.reregister(selectable: self.pipePair.outputFD,
                                    interested: interested.intersection([.write, .reset]))
        }
    }

    override func readEOF() {
        super.readEOF()
        guard self.pipePair.inputFD.isOpen else {
            return
        }
        try! self.selectableEventLoop.deregister(channel: self, mode: .input)
        try! self.pipePair.inputFD.close()
    }

    override func writeEOF() {
        guard self.pipePair.outputFD.isOpen else {
            return
        }
        try! self.selectableEventLoop.deregister(channel: self, mode: .output)
        try! self.pipePair.outputFD.close()
    }

    override func shutdownSocket(mode: CloseMode) throws {
        switch mode {
        case .input:
            try! self.selectableEventLoop.deregister(channel: self, mode: .input)
        case .output:
            try! self.selectableEventLoop.deregister(channel: self, mode: .output)
        case .all:
            break
        }
        try super.shutdownSocket(mode: mode)
    }
}

extension PipeChannel: CustomStringConvertible {
    var description: String {
        return "PipeChannel { \(self.socketDescription), active = \(self.isActive), localAddress = \(self.localAddress.debugDescription), remoteAddress = \(self.remoteAddress.debugDescription) }"
    }
}
