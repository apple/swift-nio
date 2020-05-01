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

// MARK: ServerBootstrap - Server
extension ServerBootstrap {
    /// Specifies some `ChannelOption`s to be applied to the `ServerSocketChannel`.
    /// - See: serverChannelOption
    /// - Parameter options: List of shorthand options to apply.
    /// - Returns: The updated server bootstrap (`self` being mutated)
    @inlinable
    public func serverChannelOptions(_ options: [NIOTCPServerShorthandOption]) -> ServerBootstrap {
        var toReturn = self
        for option in options {
            toReturn = toReturn.serverChannelOption(option)
        }
        return toReturn
    }
    
    @usableFromInline
    func serverChannelOption(_ option: NIOTCPServerShorthandOption) -> ServerBootstrap {
        let applier = ServerBootstrapServer_Applier(contained: self)
        return option.applyOptionDefaultMapping(applier).contained
    }
    
    fileprivate struct ServerBootstrapServer_Applier: NIOChannelOptionAppliable {
        var contained: ServerBootstrap

        func applyOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> ServerBootstrapServer_Applier {
            return ServerBootstrapServer_Applier(contained: contained.serverChannelOption(option, value: value))
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
    public func childChannelOptions(_ options: [NIOTCPShorthandOption]) -> ServerBootstrap {
        var toReturn = self
        for option in options {
            toReturn = toReturn.childChannelOption(option)
        }
        return toReturn
    }
    
    @usableFromInline
    func childChannelOption(_ option: NIOTCPShorthandOption) -> ServerBootstrap {
        let applier = ServerBootstrapChild_Applier(contained: self)
        return option.applyOptionDefaultMapping(applier).contained
    }
    
    fileprivate struct ServerBootstrapChild_Applier: NIOChannelOptionAppliable {
        var contained: ServerBootstrap

        func applyOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> ServerBootstrapChild_Applier {
            return ServerBootstrapChild_Applier(contained: contained.childChannelOption(option, value: value))
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
    public func channelOptions(_ options: [NIOTCPShorthandOption]) -> ClientBootstrap {
        var toReturn = self
        for option in options {
            toReturn = toReturn.channelOption(option)
        }
        return toReturn
    }
    
    @usableFromInline
    func channelOption(_ option: NIOTCPShorthandOption) -> ClientBootstrap {
        let applier = ClientBootstrap_Applier(contained: self)
        return option.applyOptionDefaultMapping(applier).contained
    }
    
    fileprivate struct ClientBootstrap_Applier: NIOChannelOptionAppliable {
        var contained: ClientBootstrap
        
        func applyOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> ClientBootstrap_Applier {
            return ClientBootstrap_Applier(contained: contained.channelOption(option, value: value))
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
    public func channelOptions(_ options: [NIOUDPShorthandOption]) -> DatagramBootstrap {
        var toReturn = self
        for option in options {
            toReturn = toReturn.channelOption(option)
        }
        return toReturn
    }
    
    @usableFromInline
    func channelOption(_ option: NIOUDPShorthandOption) -> DatagramBootstrap {
        let applier = DatagramBootstrap_Applier(contained: self)
        return option.applyOptionDefaultMapping(applier).contained
    }
    
    fileprivate struct DatagramBootstrap_Applier: NIOChannelOptionAppliable {
        var contained: DatagramBootstrap
        
        func applyOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> DatagramBootstrap_Applier {
            return DatagramBootstrap_Applier(contained: contained.channelOption(option, value: value))
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
    public func channelOptions(_ options: [NIOPipeShorthandOption]) -> NIOPipeBootstrap {
        var toReturn = self
        for option in options {
            toReturn = toReturn.channelOption(option)
        }
        return toReturn
    }
    
    @usableFromInline
    func channelOption(_ option: NIOPipeShorthandOption) -> NIOPipeBootstrap {
        let applier = NIOPipeBootstrap_Applier(contained: self)
        return option.applyOptionDefaultMapping(applier).contained
    }
    
    fileprivate struct NIOPipeBootstrap_Applier: NIOChannelOptionAppliable {
        var contained: NIOPipeBootstrap
        
        func applyOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> NIOPipeBootstrap_Applier {
            return NIOPipeBootstrap_Applier(contained: contained.channelOption(option, value: value))
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
        return nil
    }
}

extension NIOClientTCPBootstrap {
    /// Specifies some `ChannelOption`s to be applied to the channel.
    /// - See: channelOption
    /// - Parameter options: List of shorthand options to apply.
    /// - Returns: The updated bootstrap (`self` being mutated)
    @inlinable
    public func channelOptions(_ options: [NIOTCPShorthandOption]) -> NIOClientTCPBootstrap {
        var toReturn = self
        for option in options {
            toReturn = toReturn.channelOption(option)
        }
        return toReturn
    }
    
    @usableFromInline
    func channelOption(_ option: NIOTCPShorthandOption) -> NIOClientTCPBootstrap {
        if let updatedUnderlying = underlyingBootstrap.applyChannelOption(option) {
            return NIOClientTCPBootstrap(self, withUpdated: updatedUnderlying)
        } else {
            let applier = NIOClientTCPBootstrap_Applier(contained: self)
            return option.applyOptionDefaultMapping(applier).contained
        }
    }
    
    struct NIOClientTCPBootstrap_Applier: NIOChannelOptionAppliable {
        var contained: NIOClientTCPBootstrap
        
        func applyOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> NIOClientTCPBootstrap_Applier {
            return NIOClientTCPBootstrap_Applier(contained: contained.channelOption(option, value: value))
        }
    }
}

// MARK: Utility
/// An object which can have a 'ChannelOption' applied to it and will return an appropriately updated version of itself.
fileprivate protocol NIOChannelOptionAppliable {
    /// Apply a ChannelOption and return an updated version of self.
    func applyOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> Self
}

/// An updater which works by appending to channelOptionsStorage.
struct NIOChannelOptionsStorageApplier: NIOChannelOptionAppliable {
    /// The storage - the contents of this will be updated.
    var channelOptionsStorage: ChannelOptions.Storage
    
    public func applyOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> Self {
        var s = channelOptionsStorage
        s.append(key: option, value: value)
        return NIOChannelOptionsStorageApplier(channelOptionsStorage: s)
    }
}

// MARK: TCP - data
/// A TCP channel option which can be applied to a bootstrap using shorthand notation.
public struct NIOTCPShorthandOption  {
    private var data: ShorthandOption
    
    private init(_ data: ShorthandOption) {
        self.data = data
    }
    
    /// Apply the contained option to the supplied object (almost certainly bootstrap) using the default mapping.
    /// - Parameter optionApplier: object to use to apply the option.
    /// - Returns: the modified object
    fileprivate func applyOptionDefaultMapping<OptionApplier: NIOChannelOptionAppliable>(_ optionApplier: OptionApplier) -> OptionApplier {
        return data.applyOptionDefaultMapping(optionApplier)
    }
    
    /// Apply the contained option to the supplied ChannelOptions.Storage using the default mapping.
    /// - Parameter to: The storage to append this option to.
    /// - Returns: ChannelOptions.storage with option added.
    public func applyOptionDefaultMapping(to storage: ChannelOptions.Storage) -> ChannelOptions.Storage {
        let applier = NIOChannelOptionsStorageApplier(channelOptionsStorage: storage)
        return data.applyOptionDefaultMapping(applier).channelOptionsStorage
    }
    
    fileprivate enum ShorthandOption {
        case reuseAddr
        case disableAutoRead
        case allowRemoteHalfClosure
        
        func applyOptionDefaultMapping<OptionApplier: NIOChannelOptionAppliable>(_ optionApplier: OptionApplier) -> OptionApplier {
            switch self {
            case .reuseAddr:
                return optionApplier.applyOption(ChannelOptions.socketOption(.reuseaddr), value: 1)
            case .allowRemoteHalfClosure:
                return optionApplier.applyOption(ChannelOptions.allowRemoteHalfClosure, value: true)
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
    public static let allowImmediateLocalEndpointAddressReuse = NIOTCPShorthandOption(.reuseAddr)
    
    /// The user will manually call `Channel.read` once all the data is read from the transport.
    public static let disableAutoRead = NIOTCPShorthandOption(.disableAutoRead)
    
    /// Allows users to configure whether the `Channel` will close itself when its remote
    /// peer shuts down its send stream, or whether it will remain open. If set to `false` (the default), the `Channel`
    /// will be closed automatically if the remote peer shuts down its send stream. If set to true, the `Channel` will
    /// not be closed: instead, a `ChannelEvent.inboundClosed` user event will be sent on the `ChannelPipeline`,
    /// and no more data will be received.
    public static let allowRemoteHalfClosure =
        NIOTCPShorthandOption(.allowRemoteHalfClosure)
}

// MARK: TCP - server
/// A channel option which can be applied to bootstrap using shorthand notation.
public struct NIOTCPServerShorthandOption {
    private var data: ShorthandOption
    
    private init(_ data: ShorthandOption) {
        self.data = data
    }
    
    /// Apply the contained option to the supplied object (almost certainly bootstrap) using the default mapping.
    /// - Parameter optionApplier: object to use to apply the option.
    /// - Returns: the modified object
    fileprivate func applyOptionDefaultMapping<OptionApplier: NIOChannelOptionAppliable>(_ optionApplier: OptionApplier) -> OptionApplier {
        return data.applyOptionDefaultMapping(optionApplier)
    }
    
    /// Apply the contained option to the supplied ChannelOptions.Storage using the default mapping.
    /// - Parameter to: The storage to append this option to.
    /// - Returns: ChannelOptions.storage with option added.
    public func applyOptionDefaultMapping(to storage: ChannelOptions.Storage) -> ChannelOptions.Storage {
        let applier = NIOChannelOptionsStorageApplier(channelOptionsStorage: storage)
        return data.applyOptionDefaultMapping(applier).channelOptionsStorage
    }
    
    fileprivate enum ShorthandOption {
        case reuseAddr
        case disableAutoRead
        case backlog(Int32)
        
        func applyOptionDefaultMapping<OptionApplier: NIOChannelOptionAppliable>(_ optionApplier: OptionApplier) -> OptionApplier {
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
    public static let allowImmediateLocalEndpointAddressReuse = NIOTCPServerShorthandOption(.reuseAddr)
    
    /// The user will manually call `Channel.read` once all the data is read from the transport.
    public static let disableAutoRead = NIOTCPServerShorthandOption(.disableAutoRead)
    
    /// Allows users to configure the maximum number of connections waiting to be accepted.
    /// This is possibly advisory and exact resuilts will depend on the underlying implementation.
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
    /// - Parameter optionApplier: object to use to apply the option.
    /// - Returns: the modified object
    fileprivate func applyOptionDefaultMapping<OptionApplier: NIOChannelOptionAppliable>(_ optionApplier: OptionApplier) -> OptionApplier {
        return data.applyOptionDefaultMapping(optionApplier)
    }
    
    /// Apply the contained option to the supplied ChannelOptions.Storage using the default mapping.
    /// - Parameter to: The storage to append this option to.
    /// - Returns: ChannelOptions.storage with option added.
    public func applyOptionDefaultMapping(to storage: ChannelOptions.Storage) -> ChannelOptions.Storage {
        let applier = NIOChannelOptionsStorageApplier(channelOptionsStorage: storage)
        return data.applyOptionDefaultMapping(applier).channelOptionsStorage
    }
    
    fileprivate enum ShorthandOption {
        case reuseAddr
        case disableAutoRead
        
        func applyOptionDefaultMapping<OptionApplier: NIOChannelOptionAppliable>(_ optionApplier: OptionApplier) -> OptionApplier {
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
    public static let allowImmediateLocalEndpointAddressReuse =
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
    /// - Parameter optionApplier: object to use to apply the option.
    /// - Returns: the modified object
    fileprivate func applyOptionDefaultMapping<OptionApplier: NIOChannelOptionAppliable>(_ optionApplier: OptionApplier) -> OptionApplier {
        return data.applyOptionDefaultMapping(optionApplier)
    }
    
    /// Apply the contained option to the supplied ChannelOptions.Storage using the default mapping.
    /// - Parameter to: The storage to append this option to.
    /// - Returns: ChannelOptions.storage with option added.
    public func applyOptionDefaultMapping(to storage: ChannelOptions.Storage) -> ChannelOptions.Storage {
        let applier = NIOChannelOptionsStorageApplier(channelOptionsStorage: storage)
        return data.applyOptionDefaultMapping(applier).channelOptionsStorage
    }
    
    fileprivate enum ShorthandOption {
        case disableAutoRead
        case allowRemoteHalfClosure
        
        func applyOptionDefaultMapping<OptionApplier: NIOChannelOptionAppliable>(_ optionApplier: OptionApplier) -> OptionApplier {
            switch self {
            case .disableAutoRead:
                return optionApplier.applyOption(ChannelOptions.autoRead, value: false)
            case .allowRemoteHalfClosure:
                return optionApplier.applyOption(ChannelOptions.allowRemoteHalfClosure, value: true)
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
        NIOPipeShorthandOption(.allowRemoteHalfClosure)
}
