//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO

fileprivate final class CountReadsHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer
    
    private var readsRemaining: Int
    private let completed: EventLoopPromise<Void>
    
    var completionFuture: EventLoopFuture<Void> {
        return self.completed.futureResult
    }
    
    init(numberOfReadsExpected: Int, completionPromise: EventLoopPromise<Void>) {
        self.readsRemaining = numberOfReadsExpected
        self.completed = completionPromise
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.readsRemaining -= 1
        if self.readsRemaining <= 0 {
            self.completed.succeed(())
        }
    }
}

func run(identifier: String) {
    let numberOfIterations = 1000
    
    let serverHandler = CountReadsHandler(numberOfReadsExpected: numberOfIterations,
                                          completionPromise: group.next().makePromise())
    let serverChannel = try! DatagramBootstrap(group: group)
        // Set the handlers that are applied to the bound channel
        .channelInitializer { channel in
            return channel.pipeline.addHandler(serverHandler)
        }
        .bind(to: localhostPickPort).wait()
    defer {
        try! serverChannel.close().wait()
    }

    let remoteAddress = serverChannel.localAddress!
    
    let clientBootstrap = DatagramBootstrap(group: group)

    measure(identifier: identifier) {
        /*
         FIXME:
         * thread #3, name = 'NIO-ELT-0-#1', stop reason = Swift runtime failure: precondition failure
             frame #1: 0x0000555555637da8 test_1000_udpconnections`closure #1 in closure #2 in SelectableEventLoop.run() [inlined] generic specialization <NIO.Socket> of NIO.BaseSocketChannel.readEOF0(self=<unavailable>) -> () at BaseSocketChannel.swift:1011 [opt]

         frame #0: 0x0000555555637da8 test_1000_udpconnections`closure #1 in closure #2 in SelectableEventLoop.run() [inlined] Swift runtime failure: precondition failure at BaseSocketChannel.swift:0 [opt]
       * frame #1: 0x0000555555637da8 test_1000_udpconnections`closure #1 in closure #2 in SelectableEventLoop.run() [inlined] generic specialization <NIO.Socket> of NIO.BaseSocketChannel.readEOF0(self=<unavailable>) -> () at BaseSocketChannel.swift:1011 [opt]
         frame #2: 0x0000555555637d64 test_1000_udpconnections`closure #1 in closure #2 in SelectableEventLoop.run() [inlined] generic specialization <NIO.Socket> of NIO.BaseSocketChannel.reset(self=<unavailable>) -> () at BaseSocketChannel.swift:1024 [opt]
         frame #3: 0x0000555555637d64 test_1000_udpconnections`closure #1 in closure #2 in SelectableEventLoop.run() [inlined] inlined generic function <NIO.Socket> of protocol witness for NIO.SelectableChannel.reset() -> () in conformance NIO.BaseSocketChannel<A> : NIO.SelectableChannel in NIO at <compiler-generated>:1023 [opt]
         frame #4: 0x0000555555637d64 test_1000_udpconnections`closure #1 in closure #2 in SelectableEventLoop.run() [inlined] generic specialization <NIO.DatagramChannel> of NIO.SelectableEventLoop.handleEvent<A where A: NIO.SelectableChannel>(ev=<unavailable>, channel=<unavailable>) -> () at SelectableEventLoop.swift:317 [opt]
         frame #5: 0x0000555555637ced test_1000_udpconnections`closure #1 in closure #2 in SelectableEventLoop.run(ev=<unavailable>) at SelectableEventLoop.swift:415 [opt]
         frame #6: 0x000055555563ad34 test_1000_udpconnections`partial apply for thunk for @callee_guaranteed (@guaranteed SelectorEvent<NIORegistration>) -> (@error @owned Error) [inlined] reabstraction thunk helper from @callee_guaranteed (@guaranteed NIO.SelectorEvent<NIO.NIORegistration>) -> (@error @owned Swift.Error) to @escaping @callee_guaranteed (@in_guaranteed NIO.SelectorEvent<NIO.NIORegistration>) -> (@error @owned Swift.Error) at <compiler-generated>:0 [opt]
         frame #7: 0x000055555563ad1e test_1000_udpconnections`partial apply for thunk for @callee_guaranteed (@guaranteed SelectorEvent<NIORegistration>) -> (@error @owned Error) at <compiler-generated>:0 [opt]
         frame #8: 0x000055555563f8d0 test_1000_udpconnections`URingSelector.whenReady(strategy=<unavailable>, body=<unavailable>, self=<unavailable>) at Selector.swift:1000:25 [opt]
         frame #9: 0x000055555563667a test_1000_udpconnections`SelectableEventLoop.run() [inlined] closure #2 (self=<unavailable>, self=<invalid> @ 0x00007ffff39d9cc8) throws -> () in NIO.SelectableEventLoop.run() throws -> () at SelectableEventLoop.swift:408:36 [opt]
         frame #10: 0x00005555556365e0 test_1000_udpconnections`SelectableEventLoop.run() [inlined] reabstraction thunk helper from @callee_guaranteed () -> (@error @owned Swift.Error) to @escaping @callee_guaranteed () -> (@out (), @error @owned Swift.Error) at <compiler-generated>:0 [opt]
         frame #11: 0x00005555556365e0 test_1000_udpconnections`SelectableEventLoop.run() [inlined] generic specialization <()> of NIO.withAutoReleasePool<A>(() throws -> A) throws -> A at SelectableEventLoop.swift:26 [opt]
         frame #12: 0x00005555556365e0 test_1000_udpconnections`SelectableEventLoop.run(self=<unavailable>) at SelectableEventLoop.swift:407 [opt]
         frame #13: 0x00005555555ee7ac test_1000_udpconnections`closure #1 in static MultiThreadedEventLoopGroup.setupThreadAndEventLoop(name:selectorFactory:initializer:) at EventLoop.swift:914:22 [opt]
         frame #14: 0x00005555555ee78d test_1000_udpconnections`closure #1 in static MultiThreadedEventLoopGroup.setupThreadAndEventLoop(t=<unavailable>, selectorFactory=<unavailable>, initializer=<unavailable>, lock=<invalid> @ 0x00007ffff39d9d48, loopUpAndRunningGroup=0x0000555555784140) at EventLoop.swift:934 [opt]
         frame #15: 0x00005555555f36ba test_1000_udpconnections`partial apply for closure #1 in static MultiThreadedEventLoopGroup.setupThreadAndEventLoop(name:selectorFactory:initializer:) at <compiler-generated>:0 [opt]
         frame #16: 0x000055555562551f test_1000_udpconnections`thunk for @escaping @callee_guaranteed (@guaranteed NIOThread) -> () at <compiler-generated>:0 [opt]
         frame #17: 0x00005555555f36d1 test_1000_udpconnections`partial apply for thunk for @escaping @callee_guaranteed (@guaranteed NIOThread) -> () at <compiler-generated>:0 [opt]
         frame #18: 0x0000555555653528 test_1000_udpconnections`closure #1 in static ThreadOpsPosix.run($0=(_rawValue = 0x0000555555784250)) at ThreadPosix.swift:105:13 [opt]
         frame #19: 0x00007ffff7a30609 libpthread.so.0`start_thread(arg=<unavailable>) at pthread_create.c:477:8
         frame #20: 0x00007ffff65ca293 libc.so.6`clone + 67
     (lldb)
*/
         
        let buffer = ByteBuffer(integer: 1, as: UInt8.self)
        for _ in 0 ..< numberOfIterations {
            try! clientBootstrap.bind(to: localhostPickPort).flatMap { clientChannel -> EventLoopFuture<Void> in 
                // Send a byte to make sure everything is really open.
                let envelope = AddressedEnvelope<ByteBuffer>(remoteAddress: remoteAddress, data: buffer)
                return clientChannel.writeAndFlush(envelope).flatMap {
                    clientChannel.close()
                }
            }.wait()
        }
        try! serverHandler.completionFuture.wait()
        return numberOfIterations
    }
}

