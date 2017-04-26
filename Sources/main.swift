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

let socket = try ServerSocket.bootstrap(host: "0.0.0.0", port: 4009)

let accepted = try socket.accept()
try accepted.setNonBlocking()

var data: [UInt8] = Array(repeating: 0, count: 8 * 1024)
var offset: UInt32 = 0
var len: UInt32 = UInt32(data.count);

let selector = try Selector()
try selector.register(socket: accepted, interested: InterestedEvent.Read)

// cleanup
defer {
    do { try selector.deregister(socket: accepted) } catch { }
    do { try accepted.close() } catch { }
    do { try socket.close() } catch { }
    do { try selector.close() } catch { }
}

do {
    while true {
        if let events = try selector.awaitReady() {
            for ev in events {
                if ev.isReadable {
                    offset = 0
                    len = UInt32(data.count)
                    
                    do {
                        len = try ev.socket.read(data: &data, offset: offset, len: len)
                    } catch let err as IOError {
                        if err.errno != Glibc.EWOULDBLOCK {
                            throw err;
                        }
                        continue
                    }
                    
                    do {
                        let written = try ev.socket.write(data: data, offset: offset, len: len)
                        offset += written;
                        len -= written;
                    } catch let err as IOError {
                        if err.errno != Glibc.EWOULDBLOCK {
                            throw err;
                        }
                    }
                    if len > 0 {
                        try selector.reregister(socket: ev.socket, interested: InterestedEvent.Write)
                    }
                } else if ev.isWritable {
                    do {
                        let written = try ev.socket.write(data: data, offset: offset, len: len)
                        offset += written;
                        len -= written;
                    } catch let err as IOError {
                        if err.errno != Glibc.EWOULDBLOCK {
                            throw err;
                        }
                    }
                    if len == 0 {
                        try selector.reregister(socket: ev.socket, interested: InterestedEvent.Read)
                    }
                }
            }
        }
    }
} catch let err as IOError {
    print("{}: {}", err.reason!, err.errno)
}


