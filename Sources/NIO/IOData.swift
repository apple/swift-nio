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

public enum IOData {
    case byteBuffer(ByteBuffer)
    case fileRegion(FileRegion)
}

extension IOData: Equatable {
    public static func ==(lhs: IOData, rhs: IOData) -> Bool {
        switch (lhs, rhs) {
        case (.byteBuffer(let lhs), .byteBuffer(let rhs)):
            return lhs == rhs
        case (.fileRegion(let lhs), .fileRegion(let rhs)):
            return lhs === rhs
        default:
            return false
        }
    }
}
