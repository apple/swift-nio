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


public class Buffer {
    var data: [UInt8]
    var offset: UInt32
    var len: UInt32
    
    init(capacity: Int32) {
        self.data = Array(repeating: 0, count: 8 * 1024)
        self.offset = 0
        self.len = UInt32(data.count)
    }
    
    public func clear() {
        offset = 0
        len =  UInt32(data.count)
    }
}



let socket = try ServerSocket.bootstrap(host: "0.0.0.0", port: 4009)
try socket.setNonBlocking()

let selector = try Selector()

try selector.register(selectable: socket, interested: InterestedEvent.Read, attachment: nil)

// cleanup
defer {
    do { try selector.deregister(selectable: socket) } catch { }
    do { try socket.close() } catch { }
    do { try selector.close() } catch { }
}

do {
    while true {
        if let events = try selector.awaitReady() {
            for ev in events {
                if ev.isReadable {
                    
                    if ev.selectable is Socket {
                        let buffer = ev.attachment as! Buffer
                        buffer.clear()

                        let s = ev.selectable as! Socket
                        do {
                            buffer.len = try s.read(data: &buffer.data, offset: buffer.offset, len: buffer.len)
                        } catch let err as IOError {
                            if err.errno != Glibc.EWOULDBLOCK {
                                do { try selector.deregister(selectable: s) } catch {}
                                do { try s.close() } catch {}
                            }
                            continue
                        }
                        
                        do {
                            let written = try s.write(data: buffer.data, offset: buffer.offset, len: buffer.len)
                            buffer.offset += written;
                            buffer.len -= written;
                        } catch let err as IOError {
                            if err.errno != Glibc.EWOULDBLOCK {
                                do { try selector.deregister(selectable: s) } catch {}
                                do { try s.close() } catch {}
                                continue;
                            }
                        }
                        if buffer.len > 0 {
                            try selector.reregister(selectable: s, interested: InterestedEvent.Write)
                        }
                    } else if ev.selectable is ServerSocket {
                        let socket = ev.selectable as! ServerSocket
                        do {
                            let accepted  = try socket.accept()
                            try accepted.setNonBlocking()
                            
                            let buffer = Buffer(capacity: 8 * 1024)
                            
                            try selector.register(selectable: accepted, interested: InterestedEvent.Read, attachment: buffer)
                        } catch let err as IOError {
                            if err.errno != Glibc.EWOULDBLOCK {
                                throw err;
                            }
                        }
                    }
                    
                } else if ev.isWritable {
                    if ev.selectable is Socket {
                        let buffer = ev.attachment as! Buffer
                        
                        let s = ev.selectable as! Socket
                        do {
                            let written = try s.write(data: buffer.data, offset: buffer.offset, len: buffer.len)
                            buffer.offset += written;
                            buffer.len -= written;
                        } catch let err as IOError {
                            if err.errno != Glibc.EWOULDBLOCK {
                                do { try selector.deregister(selectable: s) } catch {}
                                do { try s.close() } catch {}
                            }
                        }
                        if buffer.len == 0 {
                            try selector.reregister(selectable: s, interested: InterestedEvent.Read)
                        }
                    }
                }
            }
        }
    }
} catch let err as IOError {
    print("{}: {}", err.reason!, err.errno)
}

