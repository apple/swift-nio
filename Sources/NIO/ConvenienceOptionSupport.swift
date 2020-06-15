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
    /// Apply any understood convenience options to the bootstrap, removing them from the set of options if they are consumed.
    /// - parameters:
    ///     - options:  The options to try applying - the options applied should be consumed from here.
    /// - returns: The updated bootstrap with and options applied.
    public func _applyChannelConvenienceOptions(_ options: inout ChannelOptions.TCPConvenienceOptions) -> Self {
        // Default is to consume no options and not update self.
        return self
    }
}

extension NIOClientTCPBootstrap {
    /// Specifies some `TCPConvenienceOption`s to be applied to the channel.
    /// These are preferred over regular channel options as they are easier to use and restrict
    /// options to those which a normal user would consider.
    /// - Parameter options: Set of convenience options to apply.
    /// - Returns: The updated bootstrap (`self` being mutated)
    public func channelConvenienceOptions(_ options: ChannelOptions.TCPConvenienceOptions) -> NIOClientTCPBootstrap {
        var optionsRemaining = options
        // First give the underlying a chance to consume options.
        let withUnderlyingOverrides =
            NIOClientTCPBootstrap(self,
                                  updating: underlyingBootstrap._applyChannelConvenienceOptions(&optionsRemaining))
        // Default apply any remaining options.
        return optionsRemaining.applyFallbackMapping(withUnderlyingOverrides)
    }
}

// MARK: Utility
extension ChannelOptions.Types {
    /// Has an option been set?
    /// Option has a value of generic type ValueType.
    public enum ConvenienceOptionValue<ValueType> {
        /// The option was not set.
        case notSet
        /// The option was set with a value of type ValueType.
        case set(ValueType)
    }
}

extension ChannelOptions.Types.ConvenienceOptionValue where ValueType == () {
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

extension ChannelOptions.Types.ConvenienceOptionValue where ValueType == () {
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
    /// A TCP channel option which can be applied to a bootstrap using convenience notation.
    public struct TCPConvenienceOption: Hashable {
        fileprivate var data: ConvenienceOption
        
        private init(_ data: ConvenienceOption) {
            self.data = data
        }
        
        fileprivate enum ConvenienceOption: Hashable {
            case allowLocalEndpointReuse
            case disableAutoRead
            case allowRemoteHalfClosure
        }
    }
}

/// Approved convenience options.
extension ChannelOptions.TCPConvenienceOption {
    /// Allow immediately reusing a local address.
    public static let allowLocalEndpointReuse = ChannelOptions.TCPConvenienceOption(.allowLocalEndpointReuse)
    
    /// The user will manually call `Channel.read` once all the data is read from the transport.
    public static let disableAutoRead = ChannelOptions.TCPConvenienceOption(.disableAutoRead)
    
    /// Allows users to configure whether the `Channel` will close itself when its remote
    /// peer shuts down its send stream, or whether it will remain open. If set to `false` (the default), the `Channel`
    /// will be closed automatically if the remote peer shuts down its send stream. If set to true, the `Channel` will
    /// not be closed: instead, a `ChannelEvent.inboundClosed` user event will be sent on the `ChannelPipeline`,
    /// and no more data will be received.
    public static let allowRemoteHalfClosure =
                        ChannelOptions.TCPConvenienceOption(.allowRemoteHalfClosure)
}

extension ChannelOptions {
    /// A set of `TCPConvenienceOption`s
    public struct TCPConvenienceOptions: ExpressibleByArrayLiteral, Hashable {
        var allowLocalEndpointReuse = false
        var disableAutoRead = false
        var allowRemoteHalfClosure = false
        
        /// Construct from an array literal.
        @inlinable
        public init(arrayLiteral elements: TCPConvenienceOption...) {
            for element in elements {
                self.add(element)
            }
        }
        
        @usableFromInline
        mutating func add(_ element: TCPConvenienceOption) {
            switch element.data {
            case .allowLocalEndpointReuse:
                self.allowLocalEndpointReuse = true
            case .allowRemoteHalfClosure:
                self.allowRemoteHalfClosure = true
            case .disableAutoRead:
                self.disableAutoRead = true
            }
        }
        
        /// Caller is consuming the knowledge that `allowLocalEndpointReuse` was set or not.
        /// The setting will nolonger be set after this call.
        /// - Returns: If `allowLocalEndpointReuse` was set.
        public mutating func consumeAllowLocalEndpointReuse() -> Types.ConvenienceOptionValue<Void> {
            defer {
                self.allowLocalEndpointReuse = false
            }
            return Types.ConvenienceOptionValue<Void>(flag: self.allowLocalEndpointReuse)
        }
        
        /// Caller is consuming the knowledge that disableAutoRead was set or not.
        /// The setting will nolonger be set after this call.
        /// - Returns: If disableAutoRead was set.
        public mutating func consumeDisableAutoRead() -> Types.ConvenienceOptionValue<Void> {
            defer {
                self.disableAutoRead = false
            }
            return Types.ConvenienceOptionValue<Void>(flag: self.disableAutoRead)
        }
        
        /// Caller is consuming the knowledge that allowRemoteHalfClosure was set or not.
        /// The setting will nolonger be set after this call.
        /// - Returns: If allowRemoteHalfClosure was set.
        public mutating func consumeAllowRemoteHalfClosure() -> Types.ConvenienceOptionValue<Void> {
            defer {
                self.allowRemoteHalfClosure = false
            }
            return Types.ConvenienceOptionValue<Void>(flag: self.allowRemoteHalfClosure)
        }
        
        mutating func applyFallbackMapping(_ universalBootstrap: NIOClientTCPBootstrap) -> NIOClientTCPBootstrap {
            var result = universalBootstrap
            if self.consumeAllowLocalEndpointReuse().isSet {
                result = result.channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            }
            if self.consumeAllowRemoteHalfClosure().isSet {
                result = result.channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            }
            if self.consumeDisableAutoRead().isSet {
                result = result.channelOption(ChannelOptions.autoRead, value: false)
            }
            return result
        }
    }
}
