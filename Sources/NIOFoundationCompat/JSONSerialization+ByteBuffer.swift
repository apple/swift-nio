//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import Foundation

extension JSONSerialization {
    
    /// Attempts to derive a Foundation object from a ByteBuffer and return it as `T`.
    ///
    /// - parameters:
    ///    - type: The Foundation type that is attempting to be derived from the ByteBuffer.
    ///    - buffer: The ByteBuffer being used to derive the Foundation type.
    /// - returns: The Foundation value if successful or `nil` if there was an issue creating the Foundation type.
    @inlinable
    public static func jsonObject<T>(_ type: T.Type, buffer: ByteBuffer) throws -> T? {
        guard let t = try JSONSerialization.jsonObject(with: Data(buffer: buffer), options: .mutableContainers) as? T else {
            return nil
        }
        return t
    }
}
