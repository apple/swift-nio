//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

/// A FIFO of the methods of requests that have been decoded but whose responses have not yet been
/// written, used by ``HTTPResponseEncoder`` to omit the body from responses to `HEAD`/`CONNECT`
/// requests (which must not carry one — RFC 9110 §9.3.2, RFC 9112 §6.3).
///
/// HTTP/1 serializes responses, so in the common case only a single request is awaiting a response
/// and its method is held inline with no heap allocation. The `overflow` buffer is only allocated
/// if a peer pipelines requests that the decoder reads ahead within a single read (so more than one
/// is pending at once); it stays `nil` — and thus allocation-free — otherwise.
struct HTTPServerRequestMethodQueue {
    /// The method of the oldest request still awaiting a response, or `nil` if none is pending.
    private var first: HTTPMethod?
    /// Methods of any further pending requests, oldest first. Allocated only under pipelining.
    private var overflow: CircularBuffer<HTTPMethod>?

    mutating func append(_ method: HTTPMethod) {
        if self.first == nil {
            self.first = method
        } else {
            if self.overflow == nil {
                self.overflow = CircularBuffer(initialCapacity: 4)
            }
            self.overflow!.append(method)
        }
    }

    mutating func popFirst() -> HTTPMethod? {
        guard let method = self.first else {
            return nil
        }
        self.first = self.overflow?.popFirst()
        return method
    }
}
