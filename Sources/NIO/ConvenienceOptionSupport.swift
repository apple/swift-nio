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
        var applier = ServerBootstrapServer_Applier(contained: self)
        for option in options {
            applier = option.applyOptionDefaultMapping(with: applier)
        }
        return applier.contained as! Self
    }
    
    @usableFromInline
    struct ServerBootstrapServer_Applier : NIOChannelOptionAppliable {
        @usableFromInline
        var contained : ServerBootstrap
        
        @usableFromInline
        init(contained: ServerBootstrap) {
            self.contained = contained
        }
        
        @usableFromInline
        func applyOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> Self {
            return Self(contained: contained.serverChannelOption(option, value: value))
        }
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
        var applier = ServerBootstrapChild_Applier(contained: self)
        for option in options {
            applier = option.applyOptionDefaultMapping(with: applier)
        }
        return applier.contained as! Self
    }
    
    @usableFromInline
    struct ServerBootstrapChild_Applier : NIOChannelOptionAppliable {
        @usableFromInline
        var contained : ServerBootstrap
        
        @usableFromInline
        init(contained: ServerBootstrap) {
            self.contained = contained
        }
        
        @usableFromInline
        func applyOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> Self {
            return Self(contained: contained.childChannelOption(option, value: value))
        }
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
        var applier = ClientBootstrap_Applier(contained: self)
        for option in options {
            applier = option.applyOptionDefaultMapping(with: applier)
        }
        return applier.contained as! Self
    }
    
    @usableFromInline
    struct ClientBootstrap_Applier : NIOChannelOptionAppliable {
        @usableFromInline
        var contained : ClientBootstrap
        
        @usableFromInline
        init(contained: ClientBootstrap) {
            self.contained = contained
        }
        
        @usableFromInline
        func applyOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> Self {
            return Self(contained: contained.channelOption(option, value: value))
        }
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
        var applier = DatagramBootstrap_Applier(contained: self)
        for option in options {
            applier = option.applyOptionDefaultMapping(with: applier)
        }
        return applier.contained as! Self
    }
    
    @usableFromInline
    struct DatagramBootstrap_Applier : NIOChannelOptionAppliable {
        @usableFromInline
        var contained : DatagramBootstrap
        
        @usableFromInline
        init(contained: DatagramBootstrap) {
            self.contained = contained
        }
        
        @usableFromInline
        func applyOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> Self {
            return Self(contained: contained.channelOption(option, value: value))
        }
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
        var applier = NIOPipeBootstrap_Applier(contained: self)
        for option in options {
            applier = option.applyOptionDefaultMapping(with: applier)
        }
        return applier.contained as! Self
    }
    
    @usableFromInline
    struct NIOPipeBootstrap_Applier : NIOChannelOptionAppliable {
        @usableFromInline
        var contained : NIOPipeBootstrap
        
        @usableFromInline
        init(contained: NIOPipeBootstrap) {
            self.contained = contained
        }
        
        @usableFromInline
        func applyOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> Self {
            return Self(contained: contained.channelOption(option, value: value))
        }
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
                let applier = NIOClientTCPBootstrap_Applier(contained: toReturn)
                toReturn = option.applyOptionDefaultMapping(with: applier).contained
            }
        }
        return toReturn
    }
    
    @usableFromInline
    struct NIOClientTCPBootstrap_Applier : NIOChannelOptionAppliable {
        @usableFromInline
        var contained : NIOClientTCPBootstrap
        
        @usableFromInline
        init(contained: NIOClientTCPBootstrap) {
            self.contained = contained
        }
        
        @usableFromInline
        func applyOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> Self {
            return Self(contained: contained.channelOption(option, value: value))
        }
    }
}

// MARK: Utility
/// An object which can have a 'ChannelOption' applied to it and will return an appropriately updated version of itself.
public protocol NIOChannelOptionAppliable {
    /// Apply a ChannelOption and return an updated version of self.
    func applyOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> Self
}

// MARK: TCP - data
/// A TCP channel option which can be applied to a bootstrap or similar using shorthand notation.
public struct NIOTCPShorthandOption  {
    private var data: ShorthandOption
    
    private init(_ data: ShorthandOption) {
        self.data = data
    }
    
    /// Apply the contained option to the supplied object (almost certainly bootstrap) using the default mapping.
    /// - Parameter with: object to use to apply the option.
    /// - Returns: the modified object
    public func applyOptionDefaultMapping<OptionApplier : NIOChannelOptionAppliable>(with optionApplier: OptionApplier) -> OptionApplier {
        return data.applyOption(with: optionApplier)
    }
    
    fileprivate enum ShorthandOption {
        case reuseAddr
        case disableAutoRead
        case allowRemoteHalfClosure(Bool)
        
        func applyOption<OptionApplier : NIOChannelOptionAppliable>(with optionApplier: OptionApplier) -> OptionApplier {
            switch self {
            case .reuseAddr:
                return optionApplier.applyOption(ChannelOptions.socketOption(.reuseaddr), value: 1)
            case .allowRemoteHalfClosure(let value):
                return optionApplier.applyOption(ChannelOptions.allowRemoteHalfClosure, value: value)
            case .disableAutoRead:
                return optionApplier.applyOption(ChannelOptions.autoRead, value: false)
            }
        }
    }
}

// Hashable for the convenience of users.
extension NIOTCPShorthandOption: Hashable {}
extension NIOTCPShorthandOption.ShorthandOption: Hashable {}

/// Approved shorthand options.
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
public struct NIOTCPServerShorthandOption {
    private var data: ShorthandOption
    
    private init(_ data: ShorthandOption) {
        self.data = data
    }
    
    /// Apply the contained option to the supplied object (almost certainly bootstrap) using the default mapping.
    /// - Parameter with: object to use to apply the option.
    /// - Returns: the modified object
    public func applyOptionDefaultMapping<OptionApplier : NIOChannelOptionAppliable>(with optionApplier: OptionApplier) -> OptionApplier {
        return data.applyOption(with: optionApplier)
    }
    
    fileprivate enum ShorthandOption {
        case reuseAddr
        case disableAutoRead
        case backlog(Int32)
        
        func applyOption<OptionApplier : NIOChannelOptionAppliable>(with optionApplier: OptionApplier) -> OptionApplier {
            switch self {
            case .disableAutoRead:
                return optionApplier.applyOption(ChannelOptions.autoRead, value: false)
            case .reuseAddr:
                return optionApplier.applyOption(ChannelOptions.socketOption(.reuseaddr),
                                                        value: 1)
            case .backlog(let value):
                return optionApplier.applyOption(ChannelOptions.backlog, value: value)
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
    
    /// Apply the contained option to the supplied object (almost certainly bootstrap) using the default mapping.
    /// - Parameter with: object to use to apply the option.
    /// - Returns: the modified object
    public func applyOptionDefaultMapping<OptionApplier : NIOChannelOptionAppliable>(with optionApplier: OptionApplier) -> OptionApplier {
        return data.applyOption(with: optionApplier)
    }
    
    fileprivate enum ShorthandOption {
        case reuseAddr
        case disableAutoRead
        
        func applyOption<OptionApplier : NIOChannelOptionAppliable>(with optionApplier: OptionApplier) -> OptionApplier {
            switch self {
            case .reuseAddr:
                return optionApplier.applyOption(ChannelOptions.socketOption(.reuseaddr), value: 1)
            case .disableAutoRead:
                return optionApplier.applyOption(ChannelOptions.autoRead, value: false)
            
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
    
    /// Apply the contained option to the supplied object (almost certainly bootstrap) using the default mapping.
    /// - Parameter with: object to use to apply the option.
    /// - Returns: the modified object
    public func applyOptionDefaultMapping<OptionApplier : NIOChannelOptionAppliable>(with optionApplier: OptionApplier) -> OptionApplier {
        return data.applyOption(with: optionApplier)
    }
    
    fileprivate enum ShorthandOption {
        case disableAutoRead
        case allowRemoteHalfClosure(Bool)
        
        func applyOption<OptionApplier : NIOChannelOptionAppliable>(with optionApplier: OptionApplier) -> OptionApplier {
            switch self {
            case .disableAutoRead:
                return optionApplier.applyOption(ChannelOptions.autoRead, value: false)
            case .allowRemoteHalfClosure(let value):
                return optionApplier.applyOption(ChannelOptions.allowRemoteHalfClosure, value: value)
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
