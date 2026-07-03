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

/// Outcome of a single attempt to fill a wide-string buffer via a Win32 API.
/// Declared at file scope because it is used from a method of a generic type,
/// where a locally-nested type is not permitted.
private enum _WideStringFillResult {
    case filled(String)
    case insufficient
    case failed(DWORD)
}

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

        // Wake-up mechanism.
        //
        // On Linux we use eventfd and on Darwin we use a kevent-only EVFILT_USER.
        // Windows has no direct equivalent. The natural-looking choice would be
        // QueueUserAPC against the event-loop thread, but APCs only fire while
        // the target thread is in an alertable wait. WSAPoll is not alertable —
        // there is no `WSAPollEx`/`SleepEx`-style waitable variant that both
        // observes the registered sockets *and* picks up APCs in one call. That
        // would force us to either spin or split the wait into two phases, both
        // of which are unacceptable from a correctness/latency perspective.
        //
        // Instead, we mirror the eventfd pattern: create a connected socket pair
        // ourselves and include the read end as the first entry in `pollFDs`.
        // `wakeup0` writes a byte to the write end; the next WSAPoll returns and
        // the read end gets drained at the top of `whenReady0`. We use a UNIX
        // domain socket pair because Windows does not have `socketpair(2)` (so
        // we emulate it via listen/connect/accept on a temporary AF_UNIX path),
        // and AF_UNIX is loopback-only — no firewall prompts, no port collisions.
        let (readSocket, writeSocket) = try Self.createWakeupSocketPair()
        self.wakeupReadSocket = readSocket
        self.wakeupWriteSocket = writeSocket

        // The read end of the wakeup pair is always the first entry in pollFDs;
        // `whenReady0` relies on this invariant to drain wakeup bytes cheaply.
        // We deliberately do *not* publish the wakeup socket in `pollFDIndexes`
        // — user-facing register/reregister/deregister operations should never
        // see or touch the wakeup slot.
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

        // Create the listener socket. The listener and the on-disk socket path
        // are only needed long enough to bootstrap the connected pair, so we
        // tear them down unconditionally on the way out.
        let listenerSocket = try NIOBSDSocket.socket(domain: .unix, type: .stream, protocolSubtype: .default)
        defer {
            _ = try? NIOBSDSocket.close(socket: listenerSocket)
            _ = socketPath.withCString { DeleteFileA($0) }
        }

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

        // Bind the listener socket. We rebind the typed `sockaddr_un`
        // pointer to the generic `sockaddr` that bind(2) expects but pass
        // the length of the original concrete struct (`addr`), which is
        // what the OS uses to interpret the address family payload.
        let addrLen = socklen_t(MemoryLayout.size(ofValue: addr))
        try withUnsafePointer(to: &addr) { addrPtr in
            try addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                try NIOBSDSocket.bind(
                    socket: listenerSocket,
                    address: socketPointer,
                    address_len: addrLen
                )
            }
        }

        // Listen for connections (backlog of 1 is enough)
        if WinSDK.listen(listenerSocket, 1) == SOCKET_ERROR {
            throw IOError(winsock: WSAGetLastError(), reason: "listen")
        }

        // Create the client (write) socket and connect
        let writeSocket = try NIOBSDSocket.socket(domain: .unix, type: .stream, protocolSubtype: .default)

        do {
            // Connect to the listener (same rebind+length pattern as above).
            try withUnsafePointer(to: &addr) { addrPtr in
                try addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    guard
                        try NIOBSDSocket.connect(
                            socket: writeSocket,
                            address: sockaddrPtr,
                            address_len: addrLen
                        )
                    else {
                        throw IOError(winsock: WSAGetLastError(), reason: "connect")
                    }
                }
            }

            // Accept the connection to get the read socket
            let readSocket = WinSDK.accept(listenerSocket, nil, nil)
            if readSocket == INVALID_SOCKET {
                throw IOError(winsock: WSAGetLastError(), reason: "accept")
            }

            return (readSocket, writeSocket)
        } catch {
            _ = try? NIOBSDSocket.close(socket: writeSocket)
            throw error
        }
    }

    /// Generates a unique socket path in the Windows temp directory.
    private static func generateUniqueSocketPath() throws -> String {
        // Retrieve the temp directory using the wide (`W`) API so that paths
        // containing non-ASCII characters (e.g. a user profile whose name has
        // Unicode in it) survive intact, and size the buffer up to the Windows
        // maximum rather than the 260-char `MAX_PATH` soft limit. The returned
        // path is terminated with a trailing backslash.
        let tempDir = try Self.fillWideStringBuffer(
            initialSize: DWORD(MAX_PATH) + 1,
            maxSize: DWORD(Int16.max),
            reason: "GetTempPath2W"
        ) { buffer in
            GetTempPath2W(DWORD(buffer.count), buffer.baseAddress)
        }

        // Generate a unique identifier using process ID, thread ID, and tick count
        // This combination ensures uniqueness within a machine
        let processID = GetCurrentProcessId()
        let threadID = GetCurrentThreadId()
        let tickCount = GetTickCount64()
        let uniqueID = "\(processID)-\(threadID)-\(tickCount)"

        return "\(tempDir)nio-wakeup-\(uniqueID).sock"
    }

    /// Calls a Win32 API that fills a null-terminated wide-string (UTF-16)
    /// buffer, growing the allocation until the value fits or `maxSize` is
    /// reached. This avoids the ANSI (`A`) APIs, which cannot represent paths
    /// outside the active code page, and the 260-char `MAX_PATH` soft limit.
    ///
    /// `body` receives the destination buffer and must return the Win32
    /// convention for these APIs: `0` on failure (with the error retrievable
    /// via `GetLastError`), the number of `WCHAR`s written excluding the null
    /// terminator on success, or a value greater than or equal to the buffer's
    /// capacity when the buffer was too small. Modeled on the equivalent helper
    /// in swift-subprocess.
    private static func fillWideStringBuffer(
        initialSize: DWORD,
        maxSize: DWORD,
        reason: String,
        _ body: (UnsafeMutableBufferPointer<WCHAR>) -> DWORD
    ) throws -> String {
        var bufferCount = max(1, min(initialSize, maxSize))
        while bufferCount <= maxSize {
            let result: _WideStringFillResult = withUnsafeTemporaryAllocation(
                of: WCHAR.self,
                capacity: Int(bufferCount)
            ) { buffer in
                let count = body(buffer)
                switch count {
                case 0:
                    return .failed(GetLastError())
                case 1..<DWORD(buffer.count):
                    return .filled(String(decodingCString: buffer.baseAddress!, as: UTF16.self))
                default:
                    return .insufficient
                }
            }
            switch result {
            case .filled(let string):
                return string
            case .failed(let win32Error):
                throw IOError(windows: win32Error, reason: reason)
            case .insufficient:
                bufferCount *= 2
            }
        }
        throw IOError(windows: DWORD(ERROR_INSUFFICIENT_BUFFER), reason: reason)
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
                guard let registration = self.registrations[Int(fd)] else {
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

            // Clean up any deregistered fds in a single linear in-place compaction
            // pass: walk `pollFDs` once with a read/write cursor, dropping entries
            // whose index is in `deregisteredFDs` and updating `pollFDIndexes`
            // for any surviving entry that shifted left. This is O(n) and avoids
            // both the previous `sorted(by: >)` (O(k log k)) and per-call
            // `pollFDs.remove(at:)` (O(n) each, O(k·n) total).
            //
            // The wakeup socket is always at `pollFDs[0]` and is never registered
            // in `pollFDIndexes`, so we treat index 0 as a fixed survivor.
            if !self.deregisteredFDs.isEmpty {
                var write = 0
                for read in 0..<self.pollFDs.count {
                    if self.deregisteredFDs.contains(read) {
                        let fd = self.pollFDs[read].fd
                        self.registrations.removeValue(forKey: Int(fd))
                        continue
                    }
                    if write != read {
                        self.pollFDs[write] = self.pollFDs[read]
                        if write != 0 {
                            self.pollFDIndexes[NIOBSDSocket.Handle(self.pollFDs[write].fd)] = write
                        }
                    }
                    write += 1
                }
                self.pollFDs.removeLast(self.pollFDs.count - write)
                self.deregisteredFDs.removeAll(keepingCapacity: true)
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
        let poll = pollfd(fd: UInt64(fileDescriptor), events: interested.wsaPollEvent, revents: 0)
        self.pollFDIndexes[fileDescriptor] = self.pollFDs.count
        self.pollFDs.append(poll)
    }

    func reregister0(
        selectableFD: NIOBSDSocket.Handle,
        fileDescriptor: NIOBSDSocket.Handle,
        oldInterested: SelectorEventSet,
        newInterested: SelectorEventSet,
        registrationID: SelectorRegistrationID
    ) throws {
        if let index = self.pollFDIndexes[fileDescriptor] {
            self.pollFDs[index].events = newInterested.wsaPollEvent
        }
    }

    func deregister0(
        selectableFD: NIOBSDSocket.Handle,
        fileDescriptor: NIOBSDSocket.Handle,
        oldInterested: SelectorEventSet,
        registrationID: SelectorRegistrationID
    ) throws {
        if let index = self.pollFDIndexes.removeValue(forKey: fileDescriptor) {
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
        self.pollFDIndexes.removeAll()
        self.deregisteredFDs.removeAll()
    }
}
#endif
#endif  // !os(WASI)
