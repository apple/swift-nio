//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// MARK: ServerBootstrap - Server
extension ServerBootstrap {
    /// Specifies some `ChannelOption`s to be applied to the `ServerSocketChannel`.
    /// - See: serverChannelOption
    /// - Parameter options: List of shorthand options to apply.
    /// - Returns: The updated server bootstrap (`self` being mutated)
    @inlinable
    public func serverChannelOptions(_ options: [NIOTCPServerShorthandOption]) -> Self {
        for option in options {
            option.applyOption(to: self)
        }
        return self
    }
}

// MARK: ServerBootstrap - Child
extension ServerBootstrap {
    /// Specifies some `ChannelOption`s to be applied to the accepted `SocketChannel`s.
    /// - See: childChannelOption
    /// - Parameter options: List of shorthand options to apply.
    /// - Returns: The update server bootstrap (`self` being mutated)
    @inlinable
    public func childChannelOptions(_ options: [NIOTCPShorthandOption]) -> Self {
        var toReturn = self
        for option in options {
            toReturn = option.applyOption(with: toReturn)
        }
        return toReturn
    }
}

// MARK: ClientBootstrap
extension ClientBootstrap {
    /// Specifies some `ChannelOption`s to be applied to the `SocketChannel`.
    /// - See: channelOption
    /// - Parameter options: List of shorthand options to apply.
    /// - Returns: The updated client bootstrap (`self` being mutated)
    @inlinable
    public func channelOptions(_ options: [NIOTCPShorthandOption]) -> Self {
        var toReturn = self
        for option in options {
            toReturn = option.applyOption(with: toReturn)
        }
        return toReturn
    }
}

// MARK: DatagramBootstrap
extension DatagramBootstrap {
    /// Specifies some `ChannelOption`s to be applied to the `DatagramChannel`.
    /// - See: channelOption
    /// - Parameter options: List of shorthand options to apply.
    /// - Returns: The updated datagram bootstrap (`self` being mutated)
    @inlinable
    public func channelOptions(_ options: [NIOUDPShorthandOption]) -> Self {
        for option in options {
            option.applyOption(to: self)
        }
        return self
    }
}

// MARK: NIOPipeBootstrap
extension NIOPipeBootstrap {
    /// Specifies some `ChannelOption`s to be applied to the `PipeChannel`.
    /// - See: channelOption
    /// - Parameter options: List of shorthand options to apply.
    /// - Returns: The updated pipe bootstrap (`self` being mutated)
    @inlinable
    public func channelOptions(_ options: [NIOPipeShorthandOption]) -> Self {
        for option in options {
            option.applyOption(to: self)
        }
        return self
    }
}

// MARK:  Universal Client Bootstrap
extension NIOClientTCPBootstrapProtocol {
    /// Apply a shorthand option to this bootstrap - default implementation which always fails to apply.
    /// - parameters:
    ///     - option:  The option to try applying.
    /// - returns: The updated bootstrap if option was successfully applied, otherwise nil suggesting the caller try another method.
    public func applyChannelOption(_ option: NIOTCPShorthandOption) -> Self? {
        return .none
    }
}

extension NIOClientTCPBootstrap {
    /// Specifies some `ChannelOption`s to be applied to the channel.
    /// - See: channelOption
    /// - Parameter options: List of shorthand options to apply.
    /// - Returns: The updated bootstrap (`self` being mutated)
    public func channelOptions(_ options: [NIOTCPShorthandOption]) -> NIOClientTCPBootstrap {
        var toReturn = self
        for option in options {
            if let updatedUnderlying = toReturn.underlyingBootstrap.applyChannelOption(option) {
                toReturn = NIOClientTCPBootstrap(toReturn, withUpdated: updatedUnderlying)
            } else {
                toReturn = option.applyOption(with: toReturn)
            }
        }
        return toReturn
    }
}

extension NIOClientTCPBootstrap : NIOTCPOptionAppliable {
    public func applyOption<Option>(_ option: Option, value: Option.Value) -> NIOClientTCPBootstrap where Option : ChannelOption {
        return self.channelOption(option, value: value)
    }
}

// MARK: TCP - data
public protocol NIOTCPOptionAppliable {
    func applyOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> Self
}

extension ServerBootstrap : NIOTCPOptionAppliable {
    public func applyOption<Option>(_ option: Option, value: Option.Value) -> Self where Option : ChannelOption {
        return self.childChannelOption(option, value: value)
    }
}

extension ClientBootstrap : NIOTCPOptionAppliable {
    public func applyOption<Option>(_ option: Option, value: Option.Value) -> Self where Option : ChannelOption {
        return self.channelOption(option, value: value)
    }
}

/// A channel option which can be applied to a bootstrap or similar using shorthand notation.
/// - See: ClientBootstrap.channelOptions(_ options: [Option])
public struct NIOTCPShorthandOption  {
    private var data: ShorthandOption
    
    private init(_ data: ShorthandOption) {
        self.data = data
    }
    
    /// Apply the contained option to the supplied object (almost certainly bootstrap) using the default mapping.
    /// - Parameter to: object to apply this option to.
    /// - Returns: the modified object
    public func applyOption<T : NIOTCPOptionAppliable>(with: T) -> T {
        return data.applyOption(with: with)
    }
    
    fileprivate enum ShorthandOption {
        case reuseAddr
        case disableAutoRead
        case allowRemoteHalfClosure(Bool)
        
        func applyOption<T : NIOTCPOptionAppliable>(with: T) -> T {
            switch self {
            case .reuseAddr:
                return with.applyOption(ChannelOptions.socketOption(.reuseaddr), value: 1)
            case .allowRemoteHalfClosure(let value):
                return with.applyOption(ChannelOptions.allowRemoteHalfClosure, value: value)
            case .disableAutoRead:
                return with.applyOption(ChannelOptions.autoRead, value: false)
            }
        }
    }
}

// Hashable for the convenience of users.
extension NIOTCPShorthandOption: Hashable {}
extension NIOTCPShorthandOption.ShorthandOption: Hashable {}

/// Approved shorthand client options.
extension NIOTCPShorthandOption {
    /// Allow immediately reusing a local address.
    public static let allowImmediateEndpointAddressReuse = NIOTCPShorthandOption(.reuseAddr)
    
    /// The user will manually call `Channel.read` once all the data is read from the transport.
    public static let disableAutoRead = NIOTCPShorthandOption(.disableAutoRead)
    
    /// Allows users to configure whether the `Channel` will close itself when its remote
    /// peer shuts down its send stream, or whether it will remain open. If set to `false` (the default), the `Channel`
    /// will be closed automatically if the remote peer shuts down its send stream. If set to true, the `Channel` will
    /// not be closed: instead, a `ChannelEvent.inboundClosed` user event will be sent on the `ChannelPipeline`,
    /// and no more data will be received.
    public static let allowRemoteHalfClosure =
        NIOTCPShorthandOption(.allowRemoteHalfClosure(true))
    
    /// Allows users to configure whether the `Channel` will close itself when its remote
    /// peer shuts down its send stream, or whether it will remain open. If set to `false` (the default), the `Channel`
    /// will be closed automatically if the remote peer shuts down its send stream. If set to true, the `Channel` will
    /// not be closed: instead, a `ChannelEvent.inboundClosed` user event will be sent on the `ChannelPipeline`,
    /// and no more data will be received.
    public static func allowRemoteHalfClosure(_ value: Bool) -> NIOTCPShorthandOption {
        return NIOTCPShorthandOption(.allowRemoteHalfClosure(value))
    }
}

// MARK: TCP - server
/// A channel option which can be applied to bootstrap using shorthand notation.
/// - See: ServerBootstrap.serverChannelOptions(_ options: [ServerOption])
public struct NIOTCPServerShorthandOption {
    private var data: ShorthandOption
    
    private init(_ data: ShorthandOption) {
        self.data = data
    }
    
    /// Apply the contained option to the supplied ServerBootstrap
    /// - Parameter serverBootstrap: bootstrap to apply this option to.
    @usableFromInline
    func applyOption(to serverBootstrap: ServerBootstrap) {
        data.applyOption(to: serverBootstrap)
    }
    
    fileprivate enum ShorthandOption {
        case reuseAddr
        case disableAutoRead
        case backlog(Int32)
        
        func applyOption(to serverBootstrap: ServerBootstrap) {
            switch self {
            case .disableAutoRead:
                _ = serverBootstrap.serverChannelOption(ChannelOptions.autoRead, value: false)
            case .reuseAddr:
                _ = serverBootstrap.serverChannelOption(ChannelOptions.socketOption(.reuseaddr),
                                                        value: 1)
            case .backlog(let value):
                _ = serverBootstrap.serverChannelOption(ChannelOptions.backlog, value: value)
            }
        }
    }
}

// Hashable for the convenience of users.
extension NIOTCPServerShorthandOption: Hashable {}
extension NIOTCPServerShorthandOption.ShorthandOption: Hashable {}

/// Approved shorthand server options.
extension NIOTCPServerShorthandOption {
    /// Allow immediately reusing a local address.
    public static let allowImmediateEndpointAddressReuse = NIOTCPServerShorthandOption(.reuseAddr)
    
    /// The user will manually call `Channel.read` once all the data is read from the transport.
    public static let disableAutoRead = NIOTCPServerShorthandOption(.disableAutoRead)
    
    /// Allows users to configure the `backlog` value as specified in `man 2 listen` - the maximum number of connections waiting to be accepted.
    public static func maximumUnacceptedConnectionBacklog(_ value: ChannelOptions.Types.BacklogOption.Value) ->
        NIOTCPServerShorthandOption {
        return NIOTCPServerShorthandOption(.backlog(value))
    }
}

// MARK: UDP
/// A channel option which can be applied to a UDP based bootstrap using shorthand notation.
/// - See: DatagramBootstrap.channelOptions(_ options: [Option])
public struct NIOUDPShorthandOption {
    private var data: ShorthandOption
    
    private init(_ data: ShorthandOption) {
        self.data = data
    }
    
    /// Apply the contained option to the supplied DatagramBootstrap
    /// - Parameter to: bootstrap to apply this option to.
    @usableFromInline
    func applyOption(to bootstrap: DatagramBootstrap) {
        data.applyOption(to: bootstrap)
    }
    
    fileprivate enum ShorthandOption {
        case reuseAddr
        case disableAutoRead
        
        func applyOption(to bootstrap: DatagramBootstrap) {
            switch self {
            case .reuseAddr:
                _ = bootstrap.channelOption(ChannelOptions.socketOption(.reuseaddr), value: 1)
            case .disableAutoRead:
                _ = bootstrap.channelOption(ChannelOptions.autoRead, value: false)
            
            }
        }
    }
}

// Hashable for the convenience of users.
extension NIOUDPShorthandOption: Hashable {}
extension NIOUDPShorthandOption.ShorthandOption: Hashable {}

/// Approved shorthand datagram channel options.
extension NIOUDPShorthandOption {
    /// Allow immediately reusing a local address.
    public static let allowImmediateEndpointAddressReuse =
            NIOUDPShorthandOption(.reuseAddr)
    
    /// The user will manually call `Channel.read` once all the data is read from the transport.
    public static let disableAutoRead = NIOUDPShorthandOption(.disableAutoRead)
}

// MARK: Pipe
/// A channel option which can be applied to pipe bootstrap using shorthand notation.
/// - See: NIOPipeBootstrap.channelOptions(_ options: [Option])
public struct NIOPipeShorthandOption {
    private let data: ShorthandOption
    
    private init(_ data: ShorthandOption) {
        self.data = data
    }
    
    /// Apply the contained option to the supplied NIOPipeBootstrap
    /// - Parameter to: bootstrap to apply this option to.
    @usableFromInline
    func applyOption(to bootstrap: NIOPipeBootstrap) {
        data.applyOption(to: bootstrap)
    }
    
    fileprivate enum ShorthandOption {
        case disableAutoRead
        case allowRemoteHalfClosure(Bool)
        
        func applyOption(to bootstrap: NIOPipeBootstrap) {
            switch self {
            case .disableAutoRead:
                _ = bootstrap.channelOption(ChannelOptions.autoRead, value: false)
            case .allowRemoteHalfClosure(let value):
                _ = bootstrap.channelOption(ChannelOptions.allowRemoteHalfClosure, value: value)
            }
        }
    }
}

// Hashable for the convenience of users.
extension NIOPipeShorthandOption: Hashable {}
extension NIOPipeShorthandOption.ShorthandOption: Hashable {}

/// Approved shorthand datagram channel options.
extension NIOPipeShorthandOption {
    /// The user will manually call `Channel.read` once all the data is read from the transport.
    public static let disableAutoRead = NIOPipeShorthandOption(.disableAutoRead)
    
    /// Allows users to configure whether the `Channel` will close itself when its remote
    /// peer shuts down its send stream, or whether it will remain open. If set to `false` (the default), the `Channel`
    /// will be closed automatically if the remote peer shuts down its send stream. If set to true, the `Channel` will
    /// not be closed: instead, a `ChannelEvent.inboundClosed` user event will be sent on the `ChannelPipeline`,
    /// and no more data will be received.
    public static let allowRemoteHalfClosure =
        NIOPipeShorthandOption(.allowRemoteHalfClosure(true))
    
    /// Allows users to configure whether the `Channel` will close itself when its remote
    /// peer shuts down its send stream, or whether it will remain open. If set to `false` (the default), the `Channel`
    /// will be closed automatically if the remote peer shuts down its send stream. If set to true, the `Channel` will
    /// not be closed: instead, a `ChannelEvent.inboundClosed` user event will be sent on the `ChannelPipeline`,
    /// and no more data will be received.
    public static func allowRemoteHalfClosure(_ value: Bool) ->
        NIOPipeShorthandOption {
        return NIOPipeShorthandOption(.allowRemoteHalfClosure(value))
    }
}
