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
//  This file contains code that ensures errno is captured correctly when doing syscalls and no ARC traffic can happen inbetween that *could* change the errno
//  value before we were able to read it.
//  Its important that all static methods are declared with `@inline(never)` so its not possible any ARC traffic happens while we need to read errno.
//
//  Created by Norman Maurer on 11/10/17.
//
#if os(Linux)
import CNIOLinux
import Glibc
#else
import Darwin
#endif

private func testForBlacklistedErrno(_ code: Int32) {
    switch code {
    case EFAULT:
        fallthrough
    case EBADF:
        fatalError("blacklisted errno \(code) \(strerror(code)!)")
    default:
        ()
    }
}

private func wrapSyscallMayBlock<T: FixedWidthInteger>(_ fn: () -> T, where: StaticString = #function) throws -> IOResult<T> {
    while true {
        do {
            return .processed(try wrapSyscall(fn, where: `where`))
        } catch let err as IOError {
            let errnoValue = err.errno
            switch errnoValue {
            case EWOULDBLOCK:
                return .wouldBlock(0)
            default:
                throw err
            }
        }
    }
}

private func wrapSyscall<T: FixedWidthInteger>(_ fn: () throws -> T, where: StaticString = #function) throws -> T {
    while true {
        let res = try fn()
        if res == -1 {
            let err = errno
            if err == EINTR {
                continue
            }
            testForBlacklistedErrno(err)
            throw ioError(errno: err, function: `where`.withUTF8Buffer { String(decoding: $0, as: UTF8.self) })
        }
        return res
    }
}

internal enum Posix {
    
    @inline(never)
    public static func close(descriptor: Int32) throws {
        _ = try wrapSyscall({ () -> Int in
            #if os(Linux)
                return Int(Glibc.close(descriptor))
            #else
                return Int(Darwin.close(descriptor))
            #endif
        })
    }
    
    @inline(never)
    public static func bind(descriptor: Int32, ptr: UnsafePointer<sockaddr>, bytes: Int) throws {
         _ = try wrapSyscall({ () -> Int in
            #if os(Linux)
                return Int(Glibc.bind(descriptor, ptr, socklen_t(bytes)))
            #else
                return Int(Darwin.bind(descriptor, ptr, socklen_t(bytes)))
            #endif
        })
    }
    
    @inline(never)
    // TODO: Allow varargs
    public static func fcntl(descriptor: Int32, command: Int32, value: Int32) throws {
        _ = try wrapSyscall({ () -> Int in
            #if os(Linux)
                return Int(Glibc.fcntl(descriptor,command, value))
            #else
                return Int(Darwin.fcntl(descriptor,command, value))
            #endif
        })
    }
    
    @inline(never)
    public static func socket(domain: Int32, type: Int32, `protocol`: Int32) throws -> Int32 {
        return try wrapSyscall({
            #if os(Linux)
                return Int32(Glibc.socket(domain, type, `protocol`))
            #else
                return Int32(Darwin.socket(domain, type, `protocol`))
            #endif
        })
    }
    
    @inline(never)
    public static func setsockopt(socket: Int32, level: Int32, optionName: Int32,
                                  optionValue: UnsafeRawPointer, optionLen: socklen_t) throws {
        _ = try wrapSyscall({ () -> Int in
            #if os(Linux)
                return Int(Glibc.setsockopt(socket, level, optionName, optionValue, optionLen))
            #else
                return Int(Darwin.setsockopt(socket, level, optionName, optionValue, optionLen))
            #endif
        })
    }
    @inline(never)
    public static func getsockopt(socket: Int32, level: Int32, optionName: Int32,
                                  optionValue: UnsafeMutableRawPointer, optionLen: UnsafeMutablePointer<socklen_t>) throws {
         _ = try wrapSyscall({ () -> Int in
            #if os(Linux)
                return Int(Glibc.getsockopt(socket, level, optionName, optionValue, optionLen))
            #else
                return Int(Darwin.getsockopt(socket, level, optionName, optionValue, optionLen))
            #endif
        })
    }

    @inline(never)
    public static func listen(descriptor: Int32, backlog: Int32) throws {
        _ = try wrapSyscall({ () -> Int32 in
            #if os(Linux)
                /* no SO_NOSIGPIPE on Linux :( */
                let _ = unsafeBitCast(Glibc.signal(SIGPIPE, SIG_IGN) as sighandler_t?, to: Int.self)
                
                return Glibc.listen(descriptor, backlog)
            #else
                return Darwin.listen(descriptor, backlog)
            #endif
        })
    }
    
    @inline(never)
    public static func accept(descriptor: Int32, addr: UnsafeMutablePointer<sockaddr>, len: UnsafeMutablePointer<socklen_t>) throws -> Int32? {
        let result: IOResult<Int> = try wrapSyscallMayBlock({
            #if os(Linux)
                return Int(Glibc.accept(descriptor, addr, len))
            #else
                let fd = Darwin.accept(descriptor, addr, len)
                if (fd != -1) {
                    // TODO: Handle return code ?
                    _ = try? Posix.fcntl(descriptor: fd, command: F_SETNOSIGPIPE, value: 1)
                }
            
                return Int(fd)
            #endif
        })
        
        switch result {
        case .processed(let fd):
            return Int32(fd)
        default:
            return nil
        }
    }
    
    @inline(never)
    public static func connect(descriptor: Int32, addr: UnsafePointer<sockaddr>, size: Int) throws -> Bool {
        do {
            _ = try wrapSyscall({ () -> Int in
                #if os(Linux)
                    return Int(Glibc.connect(descriptor, addr, socklen_t(size)))
                #else
                    return Int(Darwin.connect(descriptor, addr, socklen_t(size)))
                #endif
            })
            return true
        } catch let err as IOError {
            if err.errno == EINPROGRESS {
                return false
            }
            throw err
        }
    }
    
    @inline(never)
    public static func open(file: UnsafePointer<CChar>, oFlag: Int32) throws -> Int {
        return try wrapSyscall({
            #if os(Linux)
                return Int(Glibc.open(file, oFlag))
            #else
                return Int(Darwin.open(file, oFlag))
            #endif
        })
    }
    
    @inline(never)
    public static func write(descriptor: Int32, pointer: UnsafePointer<UInt8>, size: Int) throws -> IOResult<Int> {
        return try wrapSyscallMayBlock({
            #if os(Linux)
                return Int(Glibc.write(descriptor, pointer, size))
            #else
                return Int(Darwin.write(descriptor, pointer, size))
            #endif
        })
    }
    
    @inline(never)
    public static func writev(descriptor: Int32, iovecs: UnsafeBufferPointer<IOVector>) throws -> IOResult<Int> {
        return try wrapSyscallMayBlock({
            #if os(Linux)
                return Int(Glibc.writev(descriptor, iovecs.baseAddress!, Int32(iovecs.count)))
            #else
                return Int(Darwin.writev(descriptor, iovecs.baseAddress!, Int32(iovecs.count)))
            #endif
        })
    }
    
    @inline(never)
    public static func read(descriptor: Int32, pointer: UnsafeMutablePointer<UInt8>, size: Int) throws -> IOResult<Int> {
        return try wrapSyscallMayBlock({
            #if os(Linux)
                return Int(Glibc.read(descriptor, pointer, size))
            #else
                return Int(Darwin.read(descriptor, pointer, size))
            #endif
        })
    }
    
    // Its not really posix but exists on Linux and MacOS / BSD so just put it here for now to keep it simple
    @inline(never)
    public static func sendfile(descriptor: Int32, fd: Int32, offset: Int, count: Int) throws -> IOResult<Int> {
        var written: Int = 0
        do {
            _ = try wrapSyscall({ () -> Int in
                #if os(macOS)
                    var w: off_t = off_t(count)
                    let result = Int(Darwin.sendfile(fd, descriptor, off_t(offset), &w, nil, 0))
                    written = Int(w)
                    return result
                #else
                    var off: off_t = offset
                    let result = Glibc.sendfile(descriptor, fd, &off, count)
                    if result >= 0 {
                        written = result
                    } else {
                        written = 0
                    }
                    return result
                #endif
            })
            return .processed(written)
        } catch let err as IOError {
            if err.errno == EAGAIN {
                return .wouldBlock(written)
            }
            throw err
        }
    }
}

#if os(Linux)
internal enum TimerFd {
    public static let TFD_CLOEXEC = CNIOLinux.TFD_CLOEXEC
    public static let TFD_NONBLOCK = CNIOLinux.TFD_NONBLOCK
    
    @inline(never)
    public static func timerfd_settime(fd: Int32, flags: Int32, newValue: UnsafePointer<itimerspec>, oldValue: UnsafeMutablePointer<itimerspec>?) throws  {
        _ = try wrapSyscall({
           CNIOLinux.timerfd_settime(fd, flags, newValue, oldValue)
        })
    }
    
    @inline(never)
    public static func timerfd_create(clockId: Int32, flags: Int32) throws -> Int32 {
        return try wrapSyscall({
            CNIOLinux.timerfd_create(clockId, flags)
        })
    }
}

internal enum EventFd {
    public static let EFD_CLOEXEC = CNIOLinux.EFD_CLOEXEC
    public static let EFD_NONBLOCK = CNIOLinux.EFD_NONBLOCK
    public typealias eventfd_t = CNIOLinux.eventfd_t
    
    @inline(never)
    public static func eventfd_write(fd: Int32, value: UInt64) throws -> Int32 {
        return try wrapSyscall({
            CNIOLinux.eventfd_write(fd, value)
        })
    }
    
    @inline(never)
    public static func eventfd_read(fd: Int32, value: UnsafeMutablePointer<UInt64>) throws -> Int32 {
        return try wrapSyscall({
            CNIOLinux.eventfd_read(fd, value)
        })
    }
    
    @inline(never)
    public static func eventfd(initval: Int32, flags: Int32) throws -> Int32 {
        return try wrapSyscall({
            CNIOLinux.eventfd(0, Int32(EFD_CLOEXEC | EFD_NONBLOCK))
        })
    }
}

internal enum Epoll {
    public typealias epoll_event = CNIOLinux.epoll_event
    public static let EPOLL_CTL_ADD = CNIOLinux.EPOLL_CTL_ADD
    public static let EPOLL_CTL_MOD = CNIOLinux.EPOLL_CTL_MOD
    public static let EPOLL_CTL_DEL = CNIOLinux.EPOLL_CTL_DEL
    public static let EPOLLIN = CNIOLinux.EPOLLIN
    public static let EPOLLOUT = CNIOLinux.EPOLLOUT
    public static let EPOLLERR = CNIOLinux.EPOLLERR
    public static let EPOLLRDHUP = CNIOLinux.EPOLLRDHUP
    public static let EPOLLET = CNIOLinux.EPOLLET

    @inline(never)
    public static func epoll_create(size: Int32) throws -> Int32 {
        return try wrapSyscall({
            CNIOLinux.epoll_create(size)
        })
    }
    
    @inline(never)
    public static func epoll_ctl(epfd: Int32, op: Int32, fd: Int32, event: UnsafeMutablePointer<epoll_event>) throws -> Int32 {
        return try wrapSyscall({
            CNIOLinux.epoll_ctl(epfd, op, fd, event)
        })
    }
    
    @inline(never)
    public static func epoll_wait(epfd: Int32, events: UnsafeMutablePointer<epoll_event>, maxevents: Int32, timeout: Int32) throws -> Int32 {
        return try wrapSyscall({
            return CNIOLinux.epoll_wait(epfd, events, maxevents, timeout)
        })
    }
}
    
#else
internal enum KQueue {

    // TODO: Figure out how to specify a typealias to the kevent struct without run into trouble with the swift compiler

    @inline(never)
    public static func kqueue() throws -> Int32 {
        return try wrapSyscall({
            Darwin.kqueue()
        })
    }
    
    @inline(never)
    public static func kevent0(kq: Int32, changelist: UnsafePointer<kevent>?, nchanges: Int32, eventlist: UnsafeMutablePointer<kevent>?, nevents: Int32, timeout: UnsafePointer<Darwin.timespec>?) throws -> Int32 {
        return try wrapSyscall({ () -> Int32 in
            return kevent(kq, changelist, nchanges, eventlist, nevents, timeout)
        })
    }
}
#endif
