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

final class PipeChannel: BaseStreamSocketChannel<PipePair> {
    private let pipePair: PipePair

    internal enum Direction {
        case input
        case output
    }

    init(eventLoop: SelectableEventLoop,
         inputPipe: NIOFileHandle,
         outputPipe: NIOFileHandle) throws
    {
        pipePair = try PipePair(inputFD: inputPipe, outputFD: outputPipe)
        try super.init(socket: pipePair,
                       parent: nil,
                       eventLoop: eventLoop,
                       recvAllocator: AdaptiveRecvByteBufferAllocator())
    }

    func registrationForInput(interested: SelectorEventSet, registrationID: SelectorRegistrationID) -> NIORegistration {
        NIORegistration(channel: .pipeChannel(self, .input),
                        interested: interested,
                        registrationID: registrationID)
    }

    func registrationForOutput(interested: SelectorEventSet, registrationID: SelectorRegistrationID) -> NIORegistration {
        NIORegistration(channel: .pipeChannel(self, .output),
                        interested: interested,
                        registrationID: registrationID)
    }

    override func connectSocket(to _: SocketAddress) throws -> Bool {
        throw ChannelError.operationUnsupported
    }

    override func finishConnectSocket() throws {
        throw ChannelError.inappropriateOperationForState
    }

    override func register(selector: Selector<NIORegistration>, interested: SelectorEventSet) throws {
        try selector.register(selectable: pipePair.inputFD,
                              interested: interested.intersection([.read, .reset]),
                              makeRegistration: registrationForInput)
        try selector.register(selectable: pipePair.outputFD,
                              interested: interested.intersection([.write, .reset]),
                              makeRegistration: registrationForOutput)
    }

    override func deregister(selector: Selector<NIORegistration>, mode: CloseMode) throws {
        if mode == .all || mode == .input, pipePair.inputFD.isOpen {
            try selector.deregister(selectable: pipePair.inputFD)
        }
        if mode == .all || mode == .output, pipePair.outputFD.isOpen {
            try selector.deregister(selectable: pipePair.outputFD)
        }
    }

    override func reregister(selector: Selector<NIORegistration>, interested: SelectorEventSet) throws {
        if pipePair.inputFD.isOpen {
            try selector.reregister(selectable: pipePair.inputFD,
                                    interested: interested.intersection([.read, .reset]))
        }
        if pipePair.outputFD.isOpen {
            try selector.reregister(selectable: pipePair.outputFD,
                                    interested: interested.intersection([.write, .reset]))
        }
    }

    override func readEOF() {
        super.readEOF()
        guard pipePair.inputFD.isOpen else {
            return
        }
        try! selectableEventLoop.deregister(channel: self, mode: .input)
        try! pipePair.inputFD.close()
    }

    override func writeEOF() {
        guard pipePair.outputFD.isOpen else {
            return
        }
        try! selectableEventLoop.deregister(channel: self, mode: .output)
        try! pipePair.outputFD.close()
    }

    override func shutdownSocket(mode: CloseMode) throws {
        switch mode {
        case .input:
            try! selectableEventLoop.deregister(channel: self, mode: .input)
        case .output:
            try! selectableEventLoop.deregister(channel: self, mode: .output)
        case .all:
            break
        }
        try super.shutdownSocket(mode: mode)
    }
}

extension PipeChannel: CustomStringConvertible {
    var description: String {
        "PipeChannel { \(socketDescription), active = \(isActive), localAddress = \(localAddress.debugDescription), remoteAddress = \(remoteAddress.debugDescription) }"
    }
}
