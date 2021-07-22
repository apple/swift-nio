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
    ///    - type: The Founation type that is attempting to be derived from the ByteBuffer.
    ///    - buffer: The ByteBuffer being used to derive the Foundation type.
    ///    - readingOption: The reading option used when the parser derives the Foundation type from a ByteBuffer.
    /// - returns: The Foundation value if successful or `nil` if there was an issue creating the Foundation type.
    @inlinable
    public static func jsonObject<T>(_ type: T.Type, buffer: ByteBuffer, readingOption: ReadingOptions) throws -> T? {
        guard let t = try JSONSerialization.jsonObject(with: Data(buffer: buffer), options: readingOption) as? T else {
            return nil
        }
        return t
    }
}