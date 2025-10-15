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

final class PipeChannel: BaseStreamSocketChannel<PipePair>, @unchecked Sendable {
    private let pipePair: PipePair

    internal enum Direction {
        case input
        case output
    }

    init(
        eventLoop: SelectableEventLoop,
        input: SelectablePipeHandle?,
        output: SelectablePipeHandle?
    ) throws {
        self.pipePair = try PipePair(input: input, output: output)
        try super.init(
            socket: self.pipePair,
            parent: nil,
            eventLoop: eventLoop,
            recvAllocator: AdaptiveRecvByteBufferAllocator()
        )
    }

    func registrationForInput(interested: SelectorEventSet, registrationID: SelectorRegistrationID) -> NIORegistration {
        NIORegistration(
            channel: .pipeChannel(self, .input),
            interested: interested,
            registrationID: registrationID
        )
    }

    func registrationForOutput(interested: SelectorEventSet, registrationID: SelectorRegistrationID) -> NIORegistration
    {
        NIORegistration(
            channel: .pipeChannel(self, .output),
            interested: interested,
            registrationID: registrationID
        )
    }

    override func connectSocket(to address: SocketAddress) throws -> Bool {
        throw ChannelError._operationUnsupported
    }

    override func connectSocket(to address: VsockAddress) throws -> Bool {
        throw ChannelError._operationUnsupported
    }

    override func finishConnectSocket() throws {
        throw ChannelError._inappropriateOperationForState
    }

    override func register(selector: Selector<NIORegistration>, interested: SelectorEventSet) throws {
        if let inputSPH = self.pipePair.input {
            try selector.register(
                selectable: inputSPH,
                interested: interested.intersection([.read, .reset, .error]),
                makeRegistration: self.registrationForInput
            )
        }

        if let outputSPH = self.pipePair.output {
            try selector.register(
                selectable: outputSPH,
                interested: interested.intersection([.write, .reset, .error]),
                makeRegistration: self.registrationForOutput
            )
        }
    }

    override func deregister(selector: Selector<NIORegistration>, mode: CloseMode) throws {
        if let inputSPH = self.pipePair.input, (mode == .all || mode == .input) && inputSPH.isOpen {
            try selector.deregister(selectable: inputSPH)
        }
        if let outputSPH = self.pipePair.output, (mode == .all || mode == .output) && outputSPH.isOpen {
            try selector.deregister(selectable: outputSPH)
        }
    }

    override func reregister(selector: Selector<NIORegistration>, interested: SelectorEventSet) throws {
        if let inputSPH = self.pipePair.input, inputSPH.isOpen {
            try selector.reregister(
                selectable: inputSPH,
                interested: interested.intersection([.read, .reset, .error])
            )
        }
        if let outputSPH = self.pipePair.output, outputSPH.isOpen {
            try selector.reregister(
                selectable: outputSPH,
                interested: interested.intersection([.write, .reset, .error])
            )
        }
    }

    override func readEOF() {
        super.readEOF()
        guard let inputSPH = self.pipePair.input, inputSPH.isOpen else {
            return
        }
        try! self.selectableEventLoop.deregister(channel: self, mode: .input)
        try! inputSPH.close()
    }

    override func writeEOF() {
        guard let outputSPH = self.pipePair.output, outputSPH.isOpen else {
            return
        }
        try! self.selectableEventLoop.deregister(channel: self, mode: .output)
        try! outputSPH.close()

        // Only close the entire channel if the input is already closed.
        // If input is still open, we can continue half-duplex operation.
        var inputIsClosed = true
        if let inputSPH = self.pipePair.input {
            inputIsClosed = !inputSPH.isOpen
        }
        if inputIsClosed {
            let error = IOError(errnoCode: EPIPE, reason: "Broken pipe")
            self.close0(error: error, mode: .all, promise: nil)
        }
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
        "PipeChannel { \(self.socketDescription), active = \(self.isActive), localAddress = \(self.localAddress.debugDescription), remoteAddress = \(self.remoteAddress.debugDescription) }"
    }
}
