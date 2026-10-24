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

extension String {
    @inlinable
    init(
        backportUnsafeUninitializedCapacity capacity: Int,
        initializingUTF8With initializer: (_ buffer: UnsafeMutableBufferPointer<UInt8>) throws -> Int
    ) rethrows {
        // The buffer will store zero terminated C string
        let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: capacity + 1)
        defer {
            buffer.deallocate()
        }

        let initializedCount = try initializer(buffer)
        precondition(initializedCount <= capacity, "Overran buffer in initializer!")

        // add zero termination
        buffer[initializedCount] = 0

        self = String(cString: buffer.baseAddress!)
    }
}

// Frustratingly, Swift 5.3 shipped before the macOS 11 SDK did, so we cannot gate the availability of
// this declaration on having the 5.3 compiler. This has caused a number of build issues. While updating
// to newer Xcodes does work, we can save ourselves some hassle and just wait until 5.4 to get this
// enhancement on Apple platforms.
extension String {
    @inlinable
    init(
        customUnsafeUninitializedCapacity capacity: Int,
        initializingUTF8With initializer: (
            _ buffer: UnsafeMutableBufferPointer<UInt8>
        ) throws -> Int
    ) rethrows {
        if #available(macOS 11.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *) {
            try self.init(
                unsafeUninitializedCapacity: capacity,
                initializingUTF8With: initializer
            )
        } else {
            try self.init(
                backportUnsafeUninitializedCapacity: capacity,
                initializingUTF8With: initializer
            )
        }
    }
}
