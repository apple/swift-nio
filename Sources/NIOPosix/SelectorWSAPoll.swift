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
    }

    func deinitAssertions0() {
        // no global state. nothing to check
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

        // WSAPoll requires at least one pollFD structure. If we don't have any pending IO
        // we should just sleep. By passing true as the second argument our el can be
        // woken up by an APC (Asynchronous Procedure Call).
        if self.pollFDs.isEmpty {
            if time > 0 {
                SleepEx(UInt32(time), true)
            } else if time == -1 {
                SleepEx(INFINITE, true)
            }
        } else {
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
            } else if result == 0 {
                // nothing has happened
            } else if result == WinSDK.SOCKET_ERROR {
                throw IOError(winsock: WSAGetLastError(), reason: "WSAPoll")
            }
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
        fatalError("TODO: Unimplemented")
    }

    func deregister0(
        selectableFD: NIOBSDSocket.Handle,
        fileDescriptor: NIOBSDSocket.Handle,
        oldInterested: SelectorEventSet,
        registrationID: SelectorRegistrationID
    ) throws {
        fatalError("TODO: Unimplemented")
    }

    func wakeup0() throws {
        // will be called from a different thread
        let result = try self.myThread.withHandleUnderLock { handle in
            QueueUserAPC(wakeupTarget, handle, 0)
        }
        if result == 0 {
            let errorCode = GetLastError()
            if let errorMsg = Windows.makeErrorMessageFromCode(errorCode) {
                throw IOError(errnoCode: Int32(errorCode), reason: errorMsg)
            }
        }
    }

    func close0() throws {
        self.pollFDs.removeAll()
    }
}

private func wakeupTarget(_ ptr: UInt64) {
    // This is the target of our wakeup call.
    // We don't really need to do anything here. We just need any target
}
#endif
