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

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
@_exported import Darwin.C
#elseif os(Linux) || os(FreeBSD) || os(Android)
@_exported import Glibc
#else
let badOS = { fatalError("unsupported OS") }()
#endif

private func isBlacklistedErrno(_ code: Int32) -> Bool {
    switch code {
    case EFAULT:
        fallthrough
    case EBADF:
        return true
    default:
        return false
    }
}

/* Sorry, we really try hard to not use underscored attributes. In this case however we seem to break the inlining threshold which makes a system call take twice the time, ie. we need this exception. */
@inline(__always)
internal func wrapSyscallMayBlock<T: FixedWidthInteger>(_ fn: () throws -> T , where function: StaticString = #function) throws -> IOResult<T> {
    while true {
        let res = try fn()
        if res == -1 {
            let err = errno
            switch err {
            case EINTR:
                continue
            case EWOULDBLOCK:
                return .wouldBlock(0)
            default:
                assert(!isBlacklistedErrno(err), "blacklisted errno \(err) \(strerror(err)!)")
                throw IOError(errnoCode: err, function: function)
            }
           
        }
        return .processed(res)
    }
}

/* Sorry, we really try hard to not use underscored attributes. In this case however we seem to break the inlining threshold which makes a system call take twice the time, ie. we need this exception. */
@inline(__always)
internal func wrapSyscall<T: FixedWidthInteger>(_ fn: () throws -> T, where function: StaticString = #function) throws -> T {
    while true {
        let res = try fn()
        if res == -1 {
            let err = errno
            if err == EINTR {
                continue
            }
            assert(!isBlacklistedErrno(err), "blacklisted errno \(err) \(strerror(err)!)")
            throw IOError(errnoCode: err, function: function)
        }
        return res
    }
}

enum Shutdown {
    case RD
    case WR
    case RDWR
    
    fileprivate var cValue: CInt {
        switch self {
        case .RD:
            return CInt(SHUT_RD)
        case .WR:
            return CInt(SHUT_WR)
        case .RDWR:
            return CInt(SHUT_RDWR)
        }
    }
}

internal enum Posix {
#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
    static let SOCK_STREAM: CInt = CInt(Darwin.SOCK_STREAM)
    static let UIO_MAXIOV: Int = 1024
#elseif os(Linux) || os(FreeBSD) || os(Android)
    static let SOCK_STREAM: CInt = CInt(Glibc.SOCK_STREAM.rawValue)
    static let UIO_MAXIOV: Int = Int(Glibc.UIO_MAXIOV)
#else
    static var SOCK_STREAM: CInt {
        fatalError("unsupported OS")
    }
    static var UIO_MAXIOV: Int {
        fatalError("unsupported OS")
    }
#endif
    
    @inline(never)
    public static func shutdown(descriptor: Int32, how: Shutdown) throws {
        _ = try wrapSyscall({ () -> Int in
            #if os(Linux)
                return Int(Glibc.shutdown(descriptor, how.cValue))
            #else
                return Int(Darwin.shutdown(descriptor, how.cValue))
            #endif
        })
    }
    
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
                /* no SO_NOSIGPIPE on Linux :( */
                let _ = unsafeBitCast(Glibc.signal(SIGPIPE, SIG_IGN) as sighandler_t?, to: Int.self)
                
                return Int32(Glibc.socket(domain, type, `protocol`))
            #else
                let fd = Darwin.socket(domain, type, `protocol`)
                if fd != -1 {
                    _ = try? Posix.fcntl(descriptor: fd, command: F_SETNOSIGPIPE, value: 1)
                }
                
                return Int32(fd)
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
            if err.errnoCode == EINPROGRESS {
                return false
            }
            throw err
        }
    }
    
    @inline(never)
    public static func open(file: UnsafePointer<CChar>, oFlag: Int32, mode: mode_t) throws -> CInt {
        return try wrapSyscall({
            #if os(Linux)
                return Glibc.open(file, oFlag, mode)
            #else
                return Darwin.open(file, oFlag, mode)
            #endif
        })
    }

    @inline(never)
    public static func open(file: UnsafePointer<CChar>, oFlag: Int32) throws -> CInt {
        return try wrapSyscall({
            #if os(Linux)
                return Glibc.open(file, oFlag)
            #else
                return Darwin.open(file, oFlag)
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
    
    @discardableResult
    @inline(never)
    public static func lseek(descriptor: CInt, offset: off_t, whence: CInt) throws -> off_t {
        return try wrapSyscall({ () -> off_t in
            #if os(Linux)
                return Glibc.lseek(descriptor, offset, whence)
            #else
                return Darwin.lseek(descriptor, offset, whence)
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
            if err.errnoCode == EAGAIN {
                return .wouldBlock(written)
            }
            throw err
        }
    }

}

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
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
