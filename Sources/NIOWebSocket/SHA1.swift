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

import CNIOSHA1

/// A single SHA1 hasher.
///
/// This structure is basically a shim around the SHA1 C implementation from
/// FreeBSD that can be found in `CNIOSHA1`. The fact that we are bringing our
/// own SHA1 implementation along with us is a bit disappointing, but currently
/// it is very difficult to use the operating system native libraries to get this
/// done without forcing a hard dependency on our libressl bindings (which would
/// bring along a dependency cycle for the ride).
///
/// We were disinclined to roll our own because we don't want to have to trust
/// ourselves to get it right: the FreeBSD implementation here is battle-tested and
/// extremely trustworthy, and so is a far better solution than rolling our own.
///
/// At some point in the future the Swift standard library or Foundation may include
/// some hashing functions, or we may have platform-specific conditional deps in
/// SwiftPM. Until that time, we commit the minor sin of needing to call into C for
/// this.
internal struct SHA1 {
    private var sha1Ctx: SHA1_CTX

    /// Create a brand-new hash context.
    init() {
        self.sha1Ctx = SHA1_CTX()
        c_nio_sha1_init(&self.sha1Ctx)
    }

    /// Feed the given string into the hash context as a sequence of UTF-8 bytes.
    ///
    /// - parameters:
    ///     - string: The string that will be UTF-8 encoded and fed into the
    ///         hash context.
    mutating func update(string: String) {
        let buffer = Array(string.utf8)
        buffer.withUnsafeBufferPointer {
            self.update($0)
        }
    }

    /// Feed the bytes into the hash context.
    ///
    /// - parameters:
    ///     - bytes: The bytes to feed into the hash context.
    mutating func update(_ bytes: UnsafeBufferPointer<UInt8>) {
        c_nio_sha1_loop(&self.sha1Ctx, bytes.baseAddress!, bytes.count)
    }

    /// Complete the hashing.
    ///
    /// - returns: A 20-byte array of bytes.
    mutating func finish() -> [UInt8] {
        var hashResult: [UInt8] = Array(repeating: 0, count: 20)
        hashResult.withUnsafeMutableBufferPointer {
            $0.baseAddress!.withMemoryRebound(to: Int8.self, capacity: 20) {
                c_nio_sha1_result(&self.sha1Ctx, $0)
            }
        }
        return hashResult
    }
}
