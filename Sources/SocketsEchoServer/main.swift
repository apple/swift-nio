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

import Foundation
import Sockets

public class Buffer {
    var data: Data
    var offset: Int
    var limit: Int
    
    init(capacity: Int32) {
        self.data = Data(repeating: 0, count: Int(capacity))
        self.offset = 0
        self.limit = 0;
    }
    
    public func clear() {
        self.offset = 0
        self.limit = 0
    }
}

func deregisterAndClose<S: Selectable, R>(selector: Sockets.Selector<R>, s: S) {
    do { try selector.deregister(selectable: s) } catch {}
    do { try s.close() } catch {}
}

enum SocketRegistration: Registration {
    case socket(Socket, Buffer, InterestedEvent)
    case serverSocket(ServerSocket, Buffer?, InterestedEvent)
    var interested: InterestedEvent {
        get {
            switch self {
            case .socket(_, _, let i):
                return i
            case .serverSocket(_, _, let i):
                return i
            }
        }
        set {
            switch self {
            case .socket(let s, let b, _):
                self = .socket(s, b, newValue)
            case .serverSocket(let s, let b, _):
                self = .serverSocket(s, b, newValue)
            }
        }
    }
}

// Bootstrap the server and create the Selector on which we register our sockets.
let selector = try Sockets.Selector<SocketRegistration>()

defer {
    do { try selector.close() } catch { }
}

let server = try ServerSocket.bootstrap(host: "0.0.0.0", port: 9999)
try server.setNonBlocking()


// this will register with InterestedEvent.READ and no attachment
try selector.register(selectable: server) { i in .serverSocket(server, nil, i) }

// cleanup
defer {
    do { try selector.deregister(selectable: server) } catch { }
    do { try server.close() } catch { }
}

try server.setOption(level: SOL_SOCKET, name: SO_REUSEADDR, value: 1)

while true {
    // Block until there are events to handle
    try! selector.whenReady(strategy: .block) { ev in
        if ev.isReadable {

            // We can handle either read(...) or accept()
            switch ev.registration {
            case .socket(let socket, let buffer, _):
                // We stored the Buffer before as attachment so get it and clear the limit / offset.
                buffer.clear()
                
                do {
                    switch try socket.read(data: &buffer.data) {
                    case .processed(let read):
                        buffer.limit = Int(read)

                        switch try socket.write(data: buffer.data.subdata(in: buffer.offset..<buffer.limit)) {
                        case .processed(let written):
                            buffer.offset += Int(written)
                            
                            // We could not write everything so we reregister with InterestedEvent.Write and so get woken up once the socket becomes writable again.
                            // This also ensure we not read anymore until we were able to echo it back (backpressure FTW).
                            if buffer.offset < buffer.limit {
                                try selector.reregister(selectable: socket, interested: InterestedEvent.write)
                            }
                            
                        case .wouldBlock:
                            // We could not write everything so we reregister with InterestedEvent.Write and so get woken up once the socket becomes writable again.
                            // This also ensure we not read anymore until we were able to echo it back (backpressure FTW).
                            try selector.reregister(selectable: socket, interested: InterestedEvent.write)
                        }
                    case .wouldBlock:
                        ()
                    }
                } catch {
                    deregisterAndClose(selector: selector, s: socket)
                }
            case .serverSocket(let socket, _, _):
                // Accept new connections until there are no more in the backlog
                while let accepted = try socket.accept() {
                    try accepted.setNonBlocking()
                    try accepted.setOption(level: SOL_SOCKET, name: SO_REUSEADDR, value: 1)
                    

                    // Allocate an 8kb buffer for reading and writing and register the socket with the selector
                    let buffer = Buffer(capacity: 8 * 1024)
                    try selector.register(selectable: accepted) { i in .socket(accepted, buffer, i) }
                }
            }
        } else if ev.isWritable {
            switch ev.registration {
            case .socket(let socket, let buffer, _):
                do {
                    switch try socket.write(data: buffer.data.subdata(in: buffer.offset..<buffer.limit)) {
                    case .processed(let written):
                        buffer.offset += Int(written)

                        if buffer.offset == buffer.limit {
                            // Everything was written, reregister again with InterestedEvent.Read so we are notified once there is more data on the socket to read.
                            try selector.reregister(selectable: socket, interested: InterestedEvent.read)
                        }
                    case .wouldBlock:
                        ()
                    }
                } catch {
                    deregisterAndClose(selector: selector, s: socket)
                }
            default:
                fatalError("internal error: writable server socket")
            }
        }
    }
}
