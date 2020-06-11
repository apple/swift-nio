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

// MARK:  Universal Client Bootstrap
extension NIOClientTCPBootstrapProtocol {
    /// Apply any understood shorthand options to the bootstrap, removing them from the set of options if they are consumed.
    /// - parameters:
    ///     - options:  The options to try applying - the options applied should be consumed from here.
    /// - returns: The updated bootstrap with and options applied.
    public func _applyChannelConvenienceOptions(_ options: inout ChannelOptions.NIOTCPShorthandOptions) -> Self {
        // Default is to consume no options and not update self.
        return self
    }
}

extension NIOClientTCPBootstrap {
    /// Specifies some `ChannelOption`s to be applied to the channel.
    /// - See: channelOption
    /// - Parameter options: Set of shorthand options to apply.
    /// - Returns: The updated bootstrap (`self` being mutated)
    public func channelConvenienceOptions(_ options: ChannelOptions.NIOTCPShorthandOptions) -> NIOClientTCPBootstrap {
        var optionsRemaining = options
        // First give the underlying a chance to consume options.
        let withUnderlyingOverrides =
            NIOClientTCPBootstrap(self, withUpdated:
                                    underlyingBootstrap._applyChannelConvenienceOptions(&optionsRemaining))
        // Default apply any remaining options.
        return optionsRemaining.applyFallbackMapping(withUnderlyingOverrides)
    }
}

// MARK: Utility
extension ChannelOptions.Types {
    /// Has an option been set?
    /// Option has a value of generic type T.
    public enum NIOOptionValue<T> {
        /// The option was not set.
        case notSet
        /// The option was set with a value of type T.
        case set(T)
    }
}

extension ChannelOptions.Types.NIOOptionValue where T == () {
    /// Convenience method working with bool options as bool values for set.
    public var isSet: Bool {
        get {
            switch self {
            case .notSet:
                return false
            case .set(()):
                return true
            }
        }
    }
}

extension ChannelOptions.Types.NIOOptionValue where T == () {
    fileprivate init(flag: Bool) {
        if flag {
            self = .set(())
        } else {
            self = .notSet
        }
    }
}

// MARK: TCP - data
extension ChannelOptions {
    /// A TCP channel option which can be applied to a bootstrap using shorthand notation.
    public struct NIOTCPShorthandOption: Hashable {
        fileprivate var data: ShorthandOption
        
        private init(_ data: ShorthandOption) {
            self.data = data
        }
        
        fileprivate enum ShorthandOption: Hashable {
            case reuseAddr
            case disableAutoRead
            case allowRemoteHalfClosure
        }
    }
}

/// Approved shorthand options.
extension ChannelOptions.NIOTCPShorthandOption {
    /// Allow immediately reusing a local address.
    public static let allowImmediateLocalAddressReuse = ChannelOptions.NIOTCPShorthandOption(.reuseAddr)
    
    /// The user will manually call `Channel.read` once all the data is read from the transport.
    public static let disableAutoRead = ChannelOptions.NIOTCPShorthandOption(.disableAutoRead)
    
    /// Allows users to configure whether the `Channel` will close itself when its remote
    /// peer shuts down its send stream, or whether it will remain open. If set to `false` (the default), the `Channel`
    /// will be closed automatically if the remote peer shuts down its send stream. If set to true, the `Channel` will
    /// not be closed: instead, a `ChannelEvent.inboundClosed` user event will be sent on the `ChannelPipeline`,
    /// and no more data will be received.
    public static let allowRemoteHalfClosure =
                        ChannelOptions.NIOTCPShorthandOption(.allowRemoteHalfClosure)
}

extension ChannelOptions {
    /// A set of `NIOTCPShorthandOption`s
    public struct NIOTCPShorthandOptions: ExpressibleByArrayLiteral, Hashable {
        var allowImmediateLocalAddressReuse = false
        var disableAutoRead = false
        var allowRemoteHalfClosure = false
        
        /// Construct from an array literal.
        @inlinable
        public init(arrayLiteral elements: ChannelOptions.NIOTCPShorthandOption...) {
            for element in elements {
                add(element)
            }
        }
        
        @usableFromInline
        mutating func add(_ element: ChannelOptions.NIOTCPShorthandOption) {
            switch element.data {
            case .reuseAddr:
                self.allowImmediateLocalAddressReuse = true
            case .allowRemoteHalfClosure:
                self.allowRemoteHalfClosure = true
            case .disableAutoRead:
                self.disableAutoRead = true
            }
        }
        
        /// Caller is consuming the knowledge that allowImmediateLocalAddressReuse was set or not.
        /// The setting will nolonger be set after this call.
        /// - Returns: If allowImmediateLocalAddressReuse was set.
        public mutating func consumeAllowImmediateLocalAddressReuse() ->
                                ChannelOptions.Types.NIOOptionValue<Void> {
            defer {
                self.allowImmediateLocalAddressReuse = false
            }
            return ChannelOptions.Types.NIOOptionValue<Void>(flag: self.allowImmediateLocalAddressReuse)
        }
        
        /// Caller is consuming the knowledge that disableAutoRead was set or not.
        /// The setting will nolonger be set after this call.
        /// - Returns: If disableAutoRead was set.
        public mutating func consumeDisableAutoRead() -> ChannelOptions.Types.NIOOptionValue<Void> {
            defer {
                self.disableAutoRead = false
            }
            return ChannelOptions.Types.NIOOptionValue<Void>(flag: self.disableAutoRead)
        }
        
        /// Caller is consuming the knowledge that allowRemoteHalfClosure was set or not.
        /// The setting will nolonger be set after this call.
        /// - Returns: If allowRemoteHalfClosure was set.
        public mutating func consumeAllowRemoteHalfClosure() -> ChannelOptions.Types.NIOOptionValue<Void> {
            defer {
                self.allowRemoteHalfClosure = false
            }
            return ChannelOptions.Types.NIOOptionValue<Void>(flag: self.allowRemoteHalfClosure)
        }
        
        func applyFallbackMapping(_ universalBootstrap: NIOClientTCPBootstrap) -> NIOClientTCPBootstrap {
            var result = universalBootstrap
            if self.allowImmediateLocalAddressReuse {
                result = result.channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            }
            if self.allowRemoteHalfClosure {
                result = result.channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            }
            if self.disableAutoRead {
                result = result.channelOption(ChannelOptions.autoRead, value: false)
            }
            return result
        }
    }
}
