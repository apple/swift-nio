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

#if !os(WASI)

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

        // Create a UNIX domain socket pair for wakeup signaling.
        // Since Windows doesn't support socketpair(), we emulate it with
        // listen/connect/accept on a temporary UNIX domain socket path.
        let (readSocket, writeSocket) = try Self.createWakeupSocketPair()
        self.wakeupReadSocket = readSocket
        self.wakeupWriteSocket = writeSocket

        // Add the read end to pollFDs so WSAPoll will wake up when data is written to the write end
        let wakeupPollFD = pollfd(fd: UInt64(readSocket), events: Int16(WinSDK.POLLRDNORM), revents: 0)
        self.pollFDs.append(wakeupPollFD)

        self.lifecycleState = .open
    }

    /// Creates a pair of connected UNIX domain sockets for wakeup signaling.
    /// Since Windows doesn't support socketpair(), we emulate it with listen/connect/accept.
    /// Returns (readSocket, writeSocket) tuple.
    private static func createWakeupSocketPair() throws -> (NIOBSDSocket.Handle, NIOBSDSocket.Handle) {
        // Get a unique path for the UNIX domain socket
        let socketPath = try Self.generateUniqueSocketPath()

        // Create the listener socket
        let listenerSocket = try NIOBSDSocket.socket(domain: .unix, type: .stream, protocolSubtype: .default)

        do {
            // Set up the sockaddr_un structure
            var addr = sockaddr_un()
            addr.sun_family = ADDRESS_FAMILY(AF_UNIX)

            // Copy the path into sun_path
            let pathBytes = socketPath.utf8CString
            precondition(pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path), "Socket path too long")
            withUnsafeMutableBytes(of: &addr.sun_path) { destPtr in
                pathBytes.withUnsafeBufferPointer { srcPtr in
                    destPtr.copyMemory(from: UnsafeRawBufferPointer(srcPtr))
                }
            }

            // Bind the listener socket
            try withUnsafeBytes(of: &addr) { addrPtr in
                let socketPointer = addrPtr.baseAddress!.assumingMemoryBound(to: sockaddr.self)
                try NIOBSDSocket.bind(
                    socket: listenerSocket,
                    address: socketPointer,
                    address_len: socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }

            // Listen for connections (backlog of 1 is enough)
            if WinSDK.listen(listenerSocket, 1) == SOCKET_ERROR {
                throw IOError(winsock: WSAGetLastError(), reason: "listen")
            }

            // Create the client (write) socket and connect
            let writeSocket = try NIOBSDSocket.socket(domain: .unix, type: .stream, protocolSubtype: .default)

            do {
                // Connect to the listener
                try withUnsafeMutableBytes(of: &addr) { addrPtr in
                    let sockaddrPtr = addrPtr.baseAddress!.assumingMemoryBound(to: sockaddr.self)
                    guard
                        try NIOBSDSocket.connect(
                            socket: writeSocket,
                            address: sockaddrPtr,
                            address_len: socklen_t(MemoryLayout<sockaddr_un>.size)
                        )
                    else {
                        throw IOError(winsock: WSAGetLastError(), reason: "connect")
                    }
                }

                // Accept the connection to get the read socket
                let readSocket = WinSDK.accept(listenerSocket, nil, nil)
                if readSocket == INVALID_SOCKET {
                    throw IOError(winsock: WSAGetLastError(), reason: "accept")
                }

                // Close the listener socket - we don't need it anymore
                _ = try? NIOBSDSocket.close(socket: listenerSocket)

                // Delete the socket file - it's no longer needed after the connection is established
                _ = socketPath.withCString { DeleteFileA($0) }

                return (readSocket, writeSocket)
            } catch {
                _ = try? NIOBSDSocket.close(socket: writeSocket)
                _ = try? NIOBSDSocket.close(socket: listenerSocket)
                _ = socketPath.withCString { DeleteFileA($0) }
                throw error
            }
        } catch {
            _ = try? NIOBSDSocket.close(socket: listenerSocket)
            _ = socketPath.withCString { DeleteFileA($0) }
            throw error
        }
    }

    /// Generates a unique socket path in the Windows temp directory.
    private static func generateUniqueSocketPath() throws -> String {
        // Get the temp directory path
        var tempPathBuffer = [CChar](repeating: 0, count: Int(MAX_PATH) + 1)
        let tempPathLen = GetTempPathA(DWORD(tempPathBuffer.count), &tempPathBuffer)
        guard tempPathLen > 0 && tempPathLen < MAX_PATH else {
            throw IOError(errnoCode: ENOENT, reason: "GetTempPathA failed")
        }
        // Convert the C string to Swift String, truncating at the null terminator
        let tempDir = tempPathBuffer.withUnsafeBufferPointer { buffer in
            let utf8Bytes = buffer.prefix(Int(tempPathLen)).map { UInt8(bitPattern: $0) }
            return String(decoding: utf8Bytes, as: UTF8.self)
        }

        // Generate a unique identifier using process ID, thread ID, and tick count
        // This combination ensures uniqueness within a machine
        let processId = GetCurrentProcessId()
        let threadId = GetCurrentThreadId()
        let tickCount = GetTickCount64()
        let uniqueId = "\(processId)-\(threadId)-\(tickCount)"

        return "\(tempDir)nio-wakeup-\(uniqueId).sock"
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

        precondition(
            !self.pollFDs.isEmpty,
            "pollFDs should never be empty here, since we need an eventFD for waking up on demand"
        )
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

            // Clean up any deregistered fds. Process in descending order so that removing
            // elements doesn't invalidate the indexes of elements we still need to remove.
            for i in self.deregisteredFDs.sorted(by: >) {
                let fd = self.pollFDs[i].fd
                self.pollFDs.remove(at: i)
                self.registrations.removeValue(forKey: Int(fd))
            }
            self.deregisteredFDs.removeAll(keepingCapacity: true)
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
            self.deregisteredFDs.insert(index)
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
#endif  // !os(WASI)
