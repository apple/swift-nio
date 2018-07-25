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

/// A utility function that runs the body code only in debug builds, without
/// emitting compiler warnings.
///
/// This is currently the only way to do this in Swift: see
/// https://forums.swift.org/t/support-debug-only-code/11037 for a discussion.
internal func debugOnly(_ body: () -> Void) {
    assert({ body(); return true }())
}

/// Allows to "box" another value.
final class Box<T> {
    let value: T
    init(_ value: T) { self.value = value }
}

public enum System {
    /// A utility function that returns an estimate of the number of *logical* cores
    /// on the system.
    ///
    /// This value can be used to help provide an estimate of how many threads to use with
    /// the `MultiThreadedEventLoopGroup`. The exact ratio between this number and the number
    /// of threads to use is a matter for the programmer, and can be determined based on the
    /// specific execution behaviour of the program.
    ///
    /// - returns: The logical core count on the system.
    public static var coreCount: Int {
        return sysconf(CInt(_SC_NPROCESSORS_ONLN))
    }

    /// A utility function that enumerates the available network interfaces on this machine.
    ///
    /// This function returns values that are true for a brief snapshot in time. These results can
    /// change, and the returned values will not change to reflect them. This function must be called
    /// again to get new results.
    ///
    /// - returns: An array of network interfaces available on this machine.
    /// - throws: If an error is encountered while enumerating interfaces.
    public static func enumerateInterfaces() throws -> [NIONetworkInterface] {
        var interface: UnsafeMutablePointer<ifaddrs>? = nil
        try Posix.getifaddrs(&interface)
        let originalInterface = interface
        defer {
            freeifaddrs(originalInterface)
        }

        var results: [NIONetworkInterface] = []
        results.reserveCapacity(12)  // Arbitrary choice.
        while let concreteInterface = interface {
            if let nioInterface = NIONetworkInterface(concreteInterface.pointee) {
                results.append(nioInterface)
            }
            interface = concreteInterface.pointee.ifa_next
        }

        return results
    }
}
