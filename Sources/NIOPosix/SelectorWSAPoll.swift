//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if os(Windows)
import CNIOWindows
import NIOConcurrencyHelpers
import NIOCore
import WinSDK

extension SelectorEventSet {
    // Use this property to create pollfd's event field. Reset and errors are (hopefully) always included.
    // According to the docs we don't need to listen for them explicitly.
    // Source: https://learn.microsoft.com/en-us/windows/win32/api/winsock2/ns-winsock2-wsapollfd
    var wsaPollEvent: Int16 {
        var result: Int16 = 0
        if self.contains(.read) {
            result |= Int16(WinSDK.POLLRDNORM)
        }
        if self.contains(.write) || self.contains(.writeEOF) {
            result |= Int16(WinSDK.POLLWRNORM)
        }
        return result
    }

    // Use this initializer to create a EventSet from the wsa pollfd's revent field
    @usableFromInline
    init(revents: Int16) {
        // Event Constant   Meaning	                What to do (Typical Socket API)
        // POLLRDNORM       Normal data readable    Use recv, WSARecv, or ReadFile
        // POLLRDBAND       Priority data readable  Use recv, WSARecv (with MSG_OOB for out-of-band)
        // POLLWRNORM       Normal data writable    Use send, WSASend, or WriteFile
        // POLLWRBAND       Priority data writable  Use send (with MSG_OOB for out-of-band data)
        // POLLERR          Error condition         Use getsockopt with SO_ERROR; may need closesocket
        // POLLHUP          Closed                  Usually just cleanup: closesocket
        // POLLNVAL         Invalid fd (not open)   Fix your code; close and remove fd
        self.rawValue = 0
        let mapped = Int32(revents)
        if mapped & WinSDK.POLLRDNORM != 0 {
            self.formUnion(.read)
        }
        if mapped & WinSDK.POLLWRNORM != 0 {
            self.formUnion(.write)
        }
        if mapped & WinSDK.POLLERR != 0 {
            self.formUnion(.error)
        }
        if mapped & WinSDK.POLLHUP != 0 {
            self.formUnion(.reset)
        }
        if mapped & WinSDK.POLLNVAL != 0 {
            preconditionFailure("Invalid fd supplied.")
        }
    }
}

extension Selector: _SelectorBackendProtocol {

    func initialiseState0() throws {
        self.pollFDs.reserveCapacity(16)
        self.deregisteredFDs.reserveCapacity(16)
        
        // Create a loopback socket pair for wakeup signaling.
        // Since Windows doesn't support socketpair(), we create a pair of connected
        // loopback UDP sockets to wake up the event loop.
        let (readSocket, writeSocket) = try Self.createWakeupSocketPair()
        self.wakeupReadSocket = readSocket
        self.wakeupWriteSocket = writeSocket
        
        // Add the read end to pollFDs so WSAPoll will wake up when data is written to the write end
        let wakeupPollFD = pollfd(fd: UInt64(readSocket), events: Int16(WinSDK.POLLRDNORM), revents: 0)
        self.pollFDs.append(wakeupPollFD)
        self.deregisteredFDs.append(false)
        
        self.lifecycleState = .open
    }
    
    /// Creates a pair of connected loopback UDP sockets for wakeup signaling.
    /// Returns (readSocket, writeSocket) tuple.
    private static func createWakeupSocketPair() throws -> (NIOBSDSocket.Handle, NIOBSDSocket.Handle) {
        // Create a UDP socket to receive wakeup signals
        let readSocket = try NIOBSDSocket.socket(domain: .inet, type: .datagram, protocolSubtype: .default)
        
        do {
            // Bind to loopback on an ephemeral port
            var addr = sockaddr_in()
            addr.sin_family = ADDRESS_FAMILY(AF_INET)
            addr.sin_addr.S_un.S_addr = WinSDK.htonl(UInt32(bitPattern: INADDR_LOOPBACK))
            addr.sin_port = 0  // Let the system assign a port
            
            try withUnsafeBytes(of: &addr) { addrPtr in
                let socketPointer = addrPtr.baseAddress!.assumingMemoryBound(to: sockaddr.self)
                try NIOBSDSocket.bind(socket: readSocket, address: socketPointer, address_len: socklen_t(MemoryLayout<sockaddr_in>.size))
            }
            
            // Get the assigned port
            var boundAddr = sockaddr()
            var size = Int32(MemoryLayout<sockaddr>.size)
            try NIOBSDSocket.getsockname(socket: readSocket, address: &boundAddr, address_len: &size)
            
            // Create the write socket
            let writeSocket = try NIOBSDSocket.socket(domain: .inet, type: .datagram, protocolSubtype: .default)
            
            do {
                // Connect the write socket to the read socket's address
                guard try NIOBSDSocket.connect(socket: writeSocket, address: &boundAddr, address_len: size) else {
                    throw IOError(winsock: WSAGetLastError(), reason: "connect")
                }
                return (readSocket, writeSocket)
            } catch {
                _ = try? NIOBSDSocket.close(socket: writeSocket)
                throw error
            }
        } catch {
            _ = try? NIOBSDSocket.close(socket: readSocket)
            throw error
        }
    }

    func deinitAssertions0() {
        assert(
            self.wakeupReadSocket == NIOBSDSocket.invalidHandle,
            "wakeupReadSocket == \(self.wakeupReadSocket) in deinitAssertions0, forgot close?"
        )
        assert(
            self.wakeupWriteSocket == NIOBSDSocket.invalidHandle,
            "wakeupWriteSocket == \(self.wakeupWriteSocket) in deinitAssertions0, forgot close?"
        )
    }

    @inlinable
    func whenReady0(
        strategy: SelectorStrategy,
        onLoopBegin: () -> Void,
        _ body: (SelectorEvent<R>) throws -> Void
    ) throws {
        let time: Int32 =
            switch strategy {
            case .now:
                0

            case .block:
                -1

            case .blockUntilTimeout(let timeAmount):
                Int32(clamping: timeAmount.nanoseconds / 1_000_000)
            }

        precondition(!self.pollFDs.isEmpty, "pollFDs should never be empty here, since we need an eventFD for waking up on demand")
        // We always have at least the wakeup socket in pollFDs
        let result = self.pollFDs.withUnsafeMutableBufferPointer { ptr in
            WSAPoll(ptr.baseAddress!, UInt32(ptr.count), time)
        }

        if result > 0 {
            // something has happened
            for i in self.pollFDs.indices {
                let pollFD = self.pollFDs[i]
                guard pollFD.revents != 0 else {
                    continue
                }
                // reset the revents
                self.pollFDs[i].revents = 0
                let fd = pollFD.fd

                // Check if this is the wakeup socket
                if NIOBSDSocket.Handle(fd) == self.wakeupReadSocket {
                    // Drain the wakeup socket by reading the data that was sent
                    var buffer: UInt8 = 0
                    _ = withUnsafeMutablePointer(to: &buffer) { ptr in
                        WinSDK.recv(self.wakeupReadSocket, ptr, 1, 0)
                    }
                    continue
                }

                // If the registration is not in the Map anymore we deregistered it during the processing of whenReady(...). In this case just skip it.
                guard let registration = registrations[Int(fd)] else {
                    continue
                }

                var selectorEvent = SelectorEventSet(revents: pollFD.revents)
                // in any case we only want what the user is currently registered for & what we got
                selectorEvent = selectorEvent.intersection(registration.interested)

                guard selectorEvent != ._none else {
                    continue
                }

                try body((SelectorEvent(io: selectorEvent, registration: registration)))
            }

            // now clean up any deregistered fds
            // In reverse order so we don't have to copy elements out of the array
            // If we do in in normal order, we'll have to shift all elements after the removed one
            for i in self.deregisteredFDs.indices.reversed() {
                if self.deregisteredFDs[i] {
                    // remove this one
                    let fd = self.pollFDs[i].fd
                    self.pollFDs.remove(at: i)
                    self.deregisteredFDs.remove(at: i)
                    self.registrations.removeValue(forKey: Int(fd))
                }
            }
        } else if result == 0 {
            // nothing has happened
        } else if result == WinSDK.SOCKET_ERROR {
            throw IOError(winsock: WSAGetLastError(), reason: "WSAPoll")
        }
    }

    func register0(
        selectableFD: NIOBSDSocket.Handle,
        fileDescriptor: NIOBSDSocket.Handle,
        interested: SelectorEventSet,
        registrationID: SelectorRegistrationID
    ) throws {
        // TODO (@fabian): We need to replace the pollFDs array with something
        //                 that will allow O(1) access here.
        let poll = pollfd(fd: UInt64(fileDescriptor), events: interested.wsaPollEvent, revents: 0)
        self.pollFDs.append(poll)
        self.deregisteredFDs.append(false)
    }

    func reregister0(
        selectableFD: NIOBSDSocket.Handle,
        fileDescriptor: NIOBSDSocket.Handle,
        oldInterested: SelectorEventSet,
        newInterested: SelectorEventSet,
        registrationID: SelectorRegistrationID
    ) throws {
        if let index = self.pollFDs.firstIndex(where: { $0.fd == UInt64(fileDescriptor) }) {
            self.pollFDs[index].events = newInterested.wsaPollEvent
        }
    }

    func deregister0(
        selectableFD: NIOBSDSocket.Handle,
        fileDescriptor: NIOBSDSocket.Handle,
        oldInterested: SelectorEventSet,
        registrationID: SelectorRegistrationID
    ) throws {
        if let index = self.pollFDs.firstIndex(where: { $0.fd == UInt64(fileDescriptor) }) {
            self.deregisteredFDs[index] = true
        }
    }

    func wakeup0() throws {
        // Will be called from a different thread.
        // Write a single byte to the wakeup socket to wake up the event loop.
        try self.externalSelectorFDLock.withLock {
            guard self.wakeupWriteSocket != NIOBSDSocket.invalidHandle else {
                throw EventLoopError.shutdown
            }
            var byte: UInt8 = 0
            let result = withUnsafePointer(to: &byte) { ptr in
                WinSDK.send(self.wakeupWriteSocket, ptr, 1, 0)
            }
            if result == SOCKET_ERROR {
                throw IOError(winsock: WSAGetLastError(), reason: "send (wakeup)")
            }
        }
    }

    func close0() throws {
        // Close the wakeup sockets
        if self.wakeupReadSocket != NIOBSDSocket.invalidHandle {
            try? NIOBSDSocket.close(socket: self.wakeupReadSocket)
            self.wakeupReadSocket = NIOBSDSocket.invalidHandle
        }
        if self.wakeupWriteSocket != NIOBSDSocket.invalidHandle {
            try? NIOBSDSocket.close(socket: self.wakeupWriteSocket)
            self.wakeupWriteSocket = NIOBSDSocket.invalidHandle
        }
        self.pollFDs.removeAll()
        self.deregisteredFDs.removeAll()
    }
}
#endif
