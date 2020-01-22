//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

protocol BaseSocketProtocol: CustomStringConvertible {
    associatedtype SelectableType: Selectable

    var isOpen: Bool { get }

    func close() throws

    func bind(to address: SocketAddress) throws

    func localAddress() throws -> SocketAddress

    func remoteAddress() throws -> SocketAddress

    func setOption<T>(level: Int32, name: Int32, value: T) throws

    func getOption<T>(level: Int32, name: Int32) throws -> T
}

protocol ServerSocketProtocol: BaseSocketProtocol {
    func listen(backlog: Int32) throws

    func accept(setNonBlocking: Bool) throws -> Socket?
}

protocol SocketProtocol: BaseSocketProtocol {
    func connect(to address: SocketAddress) throws -> Bool

    func finishConnect() throws

    func write(pointer: UnsafeRawBufferPointer) throws -> IOResult<Int>

    func writev(iovecs: UnsafeBufferPointer<IOVector>) throws -> IOResult<Int>

    func sendto(pointer: UnsafeRawBufferPointer, destinationPtr: UnsafePointer<sockaddr>, destinationSize: socklen_t) throws -> IOResult<Int>

    func read(pointer: UnsafeMutableRawBufferPointer) throws -> IOResult<Int>

    func recvfrom(pointer: UnsafeMutableRawBufferPointer, storage: inout sockaddr_storage, storageLen: inout socklen_t) throws -> IOResult<Int>

    func sendFile(fd: Int32, offset: Int, count: Int) throws -> IOResult<Int>

    func recvmmsg(msgs: UnsafeMutableBufferPointer<MMsgHdr>) throws -> IOResult<Int>

    func sendmmsg(msgs: UnsafeMutableBufferPointer<MMsgHdr>) throws -> IOResult<Int>

    func shutdown(how: Shutdown) throws

    func ignoreSIGPIPE() throws
}

#if os(Linux)
// This is a lazily initialised global variable that when read for the first time, will ignore SIGPIPE.
private let globallyIgnoredSIGPIPE: Bool = {
    /* no F_SETNOSIGPIPE on Linux :( */
    _ = Glibc.signal(SIGPIPE, SIG_IGN)
    return true
}()
#endif

extension BaseSocketProtocol {
    // used by `BaseSocket` and `PipePair`.
    internal static func ignoreSIGPIPE(descriptor fd: CInt) throws {
        #if os(Linux)
        let haveWeIgnoredSIGPIEThisIsHereToTriggerIgnoringIt = globallyIgnoredSIGPIPE
        guard haveWeIgnoredSIGPIEThisIsHereToTriggerIgnoringIt else {
            fatalError("BUG in NIO. We did not ignore SIGPIPE, this code path should definitely not be reachable.")
        }
        #else
        assert(fd >= 0, "illegal file descriptor \(fd)")
        do {
            try Posix.fcntl(descriptor: fd, command: F_SETNOSIGPIPE, value: 1)
        } catch {
            _ = try? Posix.close(descriptor: fd) // don't care about failure here
            throw error
        }
        #endif
    }
}
