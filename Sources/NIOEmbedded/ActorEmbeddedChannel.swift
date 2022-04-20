//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import Dispatch
import NIOCore

#if compiler(>=5.5.2) && canImport(_Concurrency)
/// `ActorEmbeddedChannel` provides a thread-safe, Swift-concurrency-aware implementation of
/// NIO's `Channel` protocol that is focused on deterministic testing.
///
/// Importantly, this `Channel` allows users to inject I/O and to control the progress of the
/// run loop. This ensures that operations only proceed in an appropriate order.



#endif
