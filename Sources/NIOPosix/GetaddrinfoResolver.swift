//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIOCore

/// A DNS resolver built on top of the libc `getaddrinfo` function.
///
/// This is the lowest-common-denominator resolver available to NIO. It's not really a very good
/// solution because the `getaddrinfo` call blocks during the DNS resolution, meaning that this resolver
/// will block a thread for as long as it takes to perform the getaddrinfo call. To prevent it from blocking `EventLoop`
/// threads, it will offload the blocking `getaddrinfo` calls to a `DispatchQueue`.
/// One advantage from leveraging `getaddrinfo` is the automatic conformance to RFC 6724, which removes some of the work
/// needed to implement it.
///
/// This resolver is a single-use object: it can only be used to perform a single host resolution.

import Dispatch

#if os(Linux) || os(FreeBSD) || os(Android)
import CNIOLinux
#endif

#if os(Windows)
import let WinSDK.AF_INET
import let WinSDK.AF_INET6

import func WinSDK.FreeAddrInfoW
import func WinSDK.GetAddrInfoW
import func WinSDK.gai_strerrorA

import struct WinSDK.ADDRESS_FAMILY
import struct WinSDK.ADDRINFOW
import struct WinSDK.SOCKADDR_IN
import struct WinSDK.SOCKADDR_IN6
#endif

// A thread-specific variable where we store the offload queue if we're on an `SelectableEventLoop`.
let offloadQueueTSV = ThreadSpecificVariable<DispatchQueue>()


internal class GetaddrinfoResolver: NIOStreamingResolver {
    private let aiSocktype: NIOBSDSocket.SocketType
    private let aiProtocol: NIOBSDSocket.OptionLevel

    /// Create a new resolver.
    ///
    /// - parameters:
    ///     - aiSocktype: The sock type to use as hint when calling getaddrinfo.
    ///     - aiProtocol: the protocol to use as hint when calling getaddrinfo.
    init(aiSocktype: NIOBSDSocket.SocketType, aiProtocol: NIOBSDSocket.OptionLevel) {
        self.aiSocktype = aiSocktype
        self.aiProtocol = aiProtocol
    }

    /// Start a name resolution for a given name.
    ///
    /// - parameters:
    ///     - name: The name to resolve.
    ///     - destinationPort: The port we'll be connecting to.
    ///     - session: The resolution session object associated with the resolution.
    func resolve(name: String, destinationPort: Int, session: NIONameResolutionSession) {
        self.offloadQueue().async {
            self.resolveBlocking(host: name, port: destinationPort, session: session)
        }
    }

    /// Cancel an outstanding name resolution.
    ///
    /// This method is called whenever a name resolution that hasn't completed no longer has its
    /// results needed. The resolver should, if possible, abort any outstanding queries and clean
    /// up their state.
    ///
    /// This method is not guaranteed to terminate the outstanding queries.
    ///
    /// In the getaddrinfo case this is a no-op, as the resolver blocks.
    ///
    /// - parameters:
    ///     - session: The resolution session object associated with the resolution.
    func cancel(_ session: NIONameResolutionSession) {
        return
    }

    private func offloadQueue() -> DispatchQueue {
        if let offloadQueue = offloadQueueTSV.currentValue {
            return offloadQueue
        } else {
            if MultiThreadedEventLoopGroup.currentEventLoop != nil {
                // Okay, we're on an SelectableEL thread. Let's stuff our queue into the thread local.
                let offloadQueue = DispatchQueue(label: "io.swiftnio.GetaddrinfoResolver.offloadQueue")
                offloadQueueTSV.currentValue = offloadQueue
                return offloadQueue
            } else {
                return DispatchQueue.global()
            }
        }
    }

    /// Perform the DNS queries and record the result.
    ///
    /// - parameters:
    ///     - host: The hostname to do the DNS queries on.
    ///     - port: The port we'll be connecting to.
    ///     - session: The resolution session object associated with the resolution.
    private func resolveBlocking(host: String, port: Int, session: NIONameResolutionSession) {
#if os(Windows)
        host.withCString(encodedAs: UTF16.self) { wszHost in
            String(port).withCString(encodedAs: UTF16.self) { wszPort in
                var pResult: UnsafeMutablePointer<ADDRINFOW>?

                var aiHints: ADDRINFOW = ADDRINFOW()
                aiHints.ai_socktype = self.aiSocktype.rawValue
                aiHints.ai_protocol = self.aiProtocol.rawValue

                let iResult = GetAddrInfoW(wszHost, wszPort, &aiHints, &pResult)
                guard iResult == 0 else {
                    self.fail(SocketAddressError.unknown(host: host, port: port), session: session)
                    return
                }

                if let pResult = pResult {
                    self.parseAndPublishResults(pResult, host: host, session: session)
                    FreeAddrInfoW(pResult)
                } else {
                    self.fail(SocketAddressError.unsupported, session: session)
                }
            }
        }
#else
        var info: UnsafeMutablePointer<addrinfo>?

        var hint = addrinfo()
        hint.ai_socktype = self.aiSocktype.rawValue
        hint.ai_protocol = self.aiProtocol.rawValue
        guard getaddrinfo(host, String(port), &hint, &info) == 0 else {
            self.fail(SocketAddressError.unknown(host: host, port: port), session: session)
            return
        }

        if let info = info {
            self.parseAndPublishResults(info, host: host, session: session)
            freeaddrinfo(info)
        } else {
            /* this is odd, getaddrinfo returned NULL */
            self.fail(SocketAddressError.unsupported, session: session)
        }
#endif
    }

    /// Parses the DNS results from the `addrinfo` linked list.
    ///
    /// - parameters:
    ///     - info: The pointer to the first of the `addrinfo` structures in the list.
    ///     - host: The hostname we resolved.
    ///     - session: The resolution session object associated with the resolution.
#if os(Windows)
    internal typealias CAddrInfo = ADDRINFOW
#else
    internal typealias CAddrInfo = addrinfo
#endif

    private func parseAndPublishResults(_ info: UnsafeMutablePointer<CAddrInfo>, host: String, session: NIONameResolutionSession) {
        var results: [SocketAddress] = []

        var info: UnsafeMutablePointer<CAddrInfo> = info
        while true {
            let addressBytes = UnsafeRawPointer(info.pointee.ai_addr)
            switch NIOBSDSocket.AddressFamily(rawValue: info.pointee.ai_family) {
            case .inet:
                // Force-unwrap must be safe, or libc did the wrong thing.
                results.append(.init(addressBytes!.load(as: sockaddr_in.self), host: host))
            case .inet6:
                // Force-unwrap must be safe, or libc did the wrong thing.
                results.append(.init(addressBytes!.load(as: sockaddr_in6.self), host: host))
            default:
                self.fail(SocketAddressError.unsupported, session: session)
                return
            }

            guard let nextInfo = info.pointee.ai_next else {
                break
            }

            info = nextInfo
        }

        session.deliverResults(results)
        session.resolutionComplete(.success(()))
    }

    /// Record an error and fail the lookup process.
    ///
    /// - parameters:
    ///     - error: The error encountered during lookup.
    ///     - session: The resolution session object associated with the resolution.
    private func fail(_ error: Error, session: NIONameResolutionSession) {
        session.resolutionComplete(.failure(error))
    }
}
