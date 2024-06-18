//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux) || os(Android)
import SystemPackage

#if canImport(Darwin)
import Darwin
import CNIODarwin
#elseif canImport(Glibc)
import Glibc
import CNIOLinux
#elseif canImport(Musl)
import Musl
import CNIOLinux
#endif

/// Aliases for platform-dependent types used for system calls.
extension CInterop {
    #if canImport(Darwin)
    public typealias Stat = Darwin.stat
    #elseif canImport(Glibc)
    public typealias Stat = Glibc.stat
    #elseif canImport(Musl)
    public typealias Stat = Musl.stat
    #endif

    #if canImport(Darwin)
    @_spi(Testing)
    public static let maxPathLength = Darwin.PATH_MAX
    #elseif canImport(Glibc)
    @_spi(Testing)
    public static let maxPathLength = Glibc.PATH_MAX
    #elseif canImport(Musl)
    @_spi(Testing)
    public static let maxPathLength = Musl.PATH_MAX
    #endif

    #if canImport(Darwin)
    typealias DirPointer = UnsafeMutablePointer<Darwin.DIR>
    #elseif canImport(Glibc) || canImport(Musl)
    typealias DirPointer = OpaquePointer
    #endif

    #if canImport(Darwin)
    typealias DirEnt = Darwin.dirent
    #elseif canImport(Glibc)
    typealias DirEnt = Glibc.dirent
    #elseif canImport(Musl)
    typealias DirEnt = Musl.dirent
    #endif

    #if canImport(Darwin)
    typealias FTS = CNIODarwin.FTS
    typealias FTSEnt = CNIODarwin.FTSENT
    #elseif canImport(Glibc) || canImport(Musl)
    typealias FTS = CNIOLinux.FTS
    typealias FTSEnt = CNIOLinux.FTSENT
    #endif

    typealias FTSPointer = UnsafeMutablePointer<FTS>
    typealias FTSEntPointer = UnsafeMutablePointer<CInterop.FTSEnt>
}
#endif
