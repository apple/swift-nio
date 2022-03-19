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
import NIOCore
import NIOPosix
import Dispatch

// The purpose of this example is to demonstrate our recommended pattern for structuring
// NIO-using applications that want to take full advantage of async/await, while operating
// as a server.
//
// This pattern is not necessarily entirely obvious. The goal is to ensure that the business
// logic can fully take advantage of structured concurrency, ensuring that all the work tasks
// have appropriate parent tasks that will be able to cancel and monitor them as needed. This
// is not so difficult with a client, but with a server it requires substantial extra thought.
// In addition, you need to bridge the async/await world with the NIO world, which can make
// a somewhat difficult problem even more subtle.
//
// This example program implements a basic TCP echo server, with the business logic in
// async/await code. The reason to keep the logic so simple is to allow us to focus on the
// structure of the program, including the way it manages tasks.

#if canImport(_Concurrency) && compiler(>=5.5.2)
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
func main() async {
    let server = Server(host: "localhost", port: 8765)
    try! await server.run()
}

let dg = DispatchGroup()
dg.enter()
if #available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *) {
    Task {
        await main()
        dg.leave()
    }
} else {
    dg.leave()
}
dg.wait()
#else
print("ERROR: The NIO Async Await Server Demo supports Swift >= 5.5.2.")
#endif
