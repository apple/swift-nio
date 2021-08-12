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

import NIOCore
import Foundation

extension JSONSerialization {
    
    /// Attempts to derive a Foundation object from a ByteBuffer and return it as `T`.
    ///
    /// - parameters:
    ///    - buffer: The ByteBuffer being used to derive the Foundation type.
    ///    - options: The reading option used when the parser derives the Foundation type from the ByteBuffer.
    /// - returns: The Foundation value if successful or `nil` if there was an issue creating the Foundation type.
    @inlinable
    public static func jsonObject(with buffer: ByteBuffer,
                                  options opt: JSONSerialization.ReadingOptions = []) throws -> Any {
        return try JSONSerialization.jsonObject(with: Data(buffer: buffer), options: opt)
    }
}
