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

// NOTE: All the helper methods that where located here, have been moved to NIOCore. This module
//       only exists to not break adopters code for now. Please remove all your dependencies on
//       `_NIOConcurrency`. We want to remove this module soon.

import NIOCore
