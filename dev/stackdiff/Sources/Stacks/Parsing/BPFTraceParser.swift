//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation

/// Parses output from NIO's `malloc-aggregation.bt` bpftrace script.
public struct BPFTraceParser: StackParser {
    private static var allocationsRegex: Regex<(Substring, Substring)> {
        /^]: (\d+)$/
    }

    private var state: ParseState
    private var stacks: [WeightedStack]

    private init() {
        self.stacks = []
        self.state = .parsingHeader
    }

    private enum ParseResult {
        case needsNextLine
        case parsedStack(Stack, Int)
    }

    private enum ParseState {
        case parsingHeader
        case parsingStack(ParsingStackState)
    }

    private struct ParsingStackState {
        var lines: [String]

        init() {
            self.lines = []
        }

        mutating func parse(_ line: String) -> (ParseState, ParseResult) {
            if let match = line.firstMatch(of: BPFTraceParser.allocationsRegex) {
                if let count = Int(match.1) {
                    return (.parsingHeader, .parsedStack(Stack(self.lines), count))
                } else {
                    fatalError("Failed to convert '\(match.1)' to an Int")
                }
            } else {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let split = trimmed.split(separator: "+")
                self.lines.append(split.first.map { String($0) } ?? trimmed)
                return (.parsingStack(self), .needsNextLine)
            }
        }
    }

    /// Parses input which looks roughly like the following:
    ///
    /// ```
    /// Attaching 14 probes...
    ///
    ///
    /// =====
    /// This will collect stack shots of allocations and print it when you exit bpftrace.
    /// So go ahead, run your tests and then press Ctrl+C in this window to see the aggregated result
    /// =====
    /// @malloc_calls[
    ///     malloc+0
    ///     swift_allocObject+52
    ///     $s7NIOCore19ByteBufferAllocatorV023zeroCapacityWithDefaultD0_WZ+52
    ///     swift::threading_impl::once_slow(swift::threading_impl::once_t&, void (*)(void*), void*)+184
    ///     $s7NIOCore19ByteBufferAllocatorV023zeroCapacityWithDefaultD0AA0bC0Vvau+28
    ///     $s6NIOSSH25SSHConnectionStateMachineV011SentVersionC0V04idleC09allocatorAeC04IdleC0V_7NIOCore19ByteBufferAllocatorVtcfC+140
    ///     $s6NIOSSH25SSHConnectionStateMachineV22processOutboundMessage_6buffer9allocator4loopyAA10SSHMessageO_7NIOCore10ByteBufferVzAJ0mN9AllocatorVAJ9EventLoop_ptKF+2104
    ///     $s6NIOSSH13NIOSSHHandlerC12writeMessage33_8AEACA5B3544E7B06ED6DDDF9DC39B98LL_7context7promiseyAA08SSHMultiD0V_7NIOCore21ChannelHandlerContextCAJ16EventLoopPromiseVyytGSgtKF+928
    ///     $s6NIOSSH13NIOSSHHandlerC10initialize33_8AEACA5B3544E7B06ED6DDDF9DC39B98LL7contexty7NIOCore21ChannelHandlerContextC_tF+224
    ///     $s7NIOCore21ChannelHandlerContextC06invokeB6Active33_F5AC316541457BD146E3694279514AA3LLyyF+68
    ///     $s7NIOCore15ChannelPipelineC21SynchronousOperationsV04fireB10RegisteredyyFTm+44
    ///     $s11NIOEmbedded19EmbeddedChannelCoreC7NIOCore0cD0AadEP8connect02to7promiseyAD13SocketAddressO_AD16EventLoopPromiseVyytGSgtFTW+100
    ///     $s7NIOCore18HeadChannelHandlerCAA01_c8OutboundD0A2aDP7connect7context2to7promiseyAA0cD7ContextC_AA13SocketAddressOAA16EventLoopPromiseVyytGSgtFTW+96
    ///     $s7NIOCore21ChannelHandlerContextC13invokeConnect33_F5AC316541457BD146E3694279514AA3LL2to7promiseyAA13SocketAddressO_AA16EventLoopPromiseVyytGSgtF+88
    ///     $s7NIOCore23_ChannelOutboundHandlerPAAE4bind7context2to7promiseyAA0bD7ContextC_AA13SocketAddressOAA16EventLoopPromiseVyytGSgtFTf4nnnd_nTm+64
    ///     $s7NIOCore23_ChannelOutboundHandlerPAAE7connect7context2to7promiseyAA0bD7ContextC_AA13SocketAddressOAA16EventLoopPromiseVyytGSgtF+36
    ///     $s7NIOCore21ChannelHandlerContextC13invokeConnect33_F5AC316541457BD146E3694279514AA3LL2to7promiseyAA13SocketAddressO_AA16EventLoopPromiseVyytGSgtF+88
    ///     $s7NIOCore15ChannelPipelineC5bind033_F5AC316541457BD146E3694279514AA3LL2to7promiseyAA13SocketAddressO_AA16EventLoopPromiseVyytGSgtFTm+80
    ///     0xabd80ee67d34
    ///     $s11NIOEmbedded15EmbeddedChannelC7connect2to7promisey7NIOCore13SocketAddressO_AG16EventLoopPromiseVyytGSgtF+1104
    ///     $s11NIOEmbedded15EmbeddedChannelC7NIOCore0C15OutboundInvokerAadEP7connect2to7promiseyAD13SocketAddressO_AD16EventLoopPromiseVyytGSgtFTW+20
    ///     $s7NIOCore22ChannelOutboundInvokerPAAE7connect2to4file4lineAA15EventLoopFutureCyytGAA13SocketAddressO_s12StaticStringVSutFTf4nddn_n+76
    ///     $s16NIOSSHBenchmarks26runOneCommandPerConnection19numberOfConnectionsySi_tKF+964
    ///     $s16NIOSSHBenchmarks10benchmarksyycvpfiyycfU_y9BenchmarkACCKcfU_+68
    ///     $s9BenchmarkAAC_13configuration7closure5setup8teardownABSgSS_AB13ConfigurationVyABKcyyYaKcSgAJtcfcyABcfU_+48
    ///     0xabd80ecd9a0c
    ///     0xabd80ecfab98
    ///     swift::runJobInEstablishedExecutorContext(swift::Job*)+412
    ///     swift_job_run+156
    ///     _dispatch_continuation_pop+236
    ///     _dispatch_async_redirect_invoke+184
    ///     _dispatch_worker_thread+432
    ///     0xe35cdd8c595c
    ///     0xe35cdd92ba4c
    /// ]: 1
    /// ```
    private mutating func parse(lines: some Sequence<String>) -> [WeightedStack] {
        for line in lines {
            switch self.parseNextState(line) {
            case .parsedStack(let stack, let count):
                self.stacks.append(WeightedStack(stack: stack, allocations: count))

            case .needsNextLine:
                ()
            }
        }

        return self.stacks
    }

    private mutating func parseNextState(_ line: String) -> ParseResult {
        switch self.state {
        case .parsingHeader:
            if line == "@malloc_calls[" {
                self.state = .parsingStack(ParsingStackState())
                return .needsNextLine
            } else {
                return .needsNextLine
            }

        case .parsingStack(var state):
            let (state, result) = state.parse(line)
            self.state = state
            return result
        }
    }
}

extension BPFTraceParser {
    public static func parse(lines: some Sequence<String>) -> [WeightedStack] {
        var parser = Self()
        return parser.parse(lines: lines)
    }
}
