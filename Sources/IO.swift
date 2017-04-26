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

import Foundation

public struct IOError: Swift.Error {
    
    public internal(set) var errno: Int32
    public internal(set) var reason: String?
    
    init(errno: Int32, reason: String) {
        self.errno = errno
        self.reason = reason
    }
}
