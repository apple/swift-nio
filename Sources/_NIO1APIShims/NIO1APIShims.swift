//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import NIOHTTP1
import NIOTLS

#if !NIO_CI_BUILD
#warning("""
         If you are a user: Please ignore this warning, it's the SwiftNIO team's fault.

         If you are developer of a package depending on NIO:
            You're using NIO 2's 'NIO1 API Shims' module.
            Please note that _NIO1APIShimsHelpers is a transitional module that is untested and
            is not part of the public API. Before NIO 2.0.0 gets released it's still very useful
            to `import _NIO1APIShimsHelpers` because it will make it easier for you to keep up
            with NIO2 API changes until the API will stabilise and we will start tagging versions.

            Sorry for causing you extra work but we believe the public API changes we're introducing
            will eventually help us all becoming a better ecosystem.

            💜 the SwiftNIO team.
        """)
#endif

@available(*, deprecated, message: "ContiguousCollection does not exist in NIO2")
public protocol ContiguousCollection: Collection {
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R
}

@available(*, deprecated, renamed: "SNIResult")
public typealias SniResult = SNIResult

@available(*, deprecated, renamed: "SNIHandler")
public typealias SniHandler = SNIHandler

@available(*, deprecated, message: "don't use the StaticString: Collection extension please")
extension StaticString: Collection {
    @available(*, deprecated, message: "don't use the StaticString: Collection extension please")
    public typealias Element = UInt8
    @available(*, deprecated, message: "don't use the StaticString: Collection extension please")
    public typealias SubSequence = ArraySlice<UInt8>

    @available(*, deprecated, message: "don't use the StaticString: Collection extension please")
    public typealias _Index = Int

    @available(*, deprecated, message: "don't use the StaticString: Collection extension please")
    public var startIndex: _Index { return 0 }
    @available(*, deprecated, message: "don't use the StaticString: Collection extension please")
    public var endIndex: _Index { return self.utf8CodeUnitCount }
    @available(*, deprecated, message: "don't use the StaticString: Collection extension please")
    public func index(after i: _Index) -> _Index { return i + 1 }

    @available(*, deprecated, message: "don't use the StaticString: Collection extension please")
    public subscript(position: Int) -> UInt8 {
        precondition(position < self.utf8CodeUnitCount, "index \(position) out of bounds")
        return self.utf8Start.advanced(by: position).pointee
    }
}

extension ChannelPipeline {
    @available(*, deprecated, message: "please use ByteToMessageHandler(myByteToMessageDecoder)")
    public func add<Decoder: ByteToMessageDecoder>(handler decoder: Decoder) -> EventLoopFuture<Void> {
        return self.add(handler: ByteToMessageHandler(decoder))
    }
}

extension EventLoop {
    @available(*, deprecated, renamed: "makePromise")
    public func newPromise<T>(of type: T.Type = T.self, file: StaticString = #file, line: UInt = #line) -> EventLoopPromise<T> {
        return self.makePromise(of: type, file: file, line: line)
    }

    @available(*, deprecated, renamed: "makeSucceededFuture")
    public func newSucceededFuture<T>(result: T) -> EventLoopFuture<T> {
        return self.makeSucceededFuture(result: result)
    }

    @available(*, deprecated, renamed: "makeFailedFuture")
    public func newFailedFuture<T>(error: Error) -> EventLoopFuture<T> {
        return self.makeFailedFuture(error: error)
    }
}

extension EventLoopFuture {
    @available(*, deprecated, renamed: "Value")
    public typealias T = Value

    @available(*, deprecated, message: "whenComplete now gets Result<Value, Error>")
    public func whenComplete(_ body: @escaping () -> Void) {
        self.whenComplete { (_: Result) in
            body()
        }
    }

    @available(*, deprecated, renamed: "flatMap")
    public func then<U>(file: StaticString = #file, line: UInt = #line, _ callback: @escaping (Value) -> EventLoopFuture<U>) -> EventLoopFuture<U> {
        return self.flatMap(file: file, line: line, callback)
    }

    @available(*, deprecated, renamed: "flatMapThrowing")
    public func thenThrowing<U>(file: StaticString = #file, line: UInt = #line, _ callback: @escaping (Value) throws -> U) -> EventLoopFuture<U> {
        return self.flatMapThrowing(file: file, line: line, callback)
    }

    @available(*, deprecated, renamed: "flatMapError")
    public func thenIfError(file: StaticString = #file, line: UInt = #line, _ callback: @escaping (Error) -> EventLoopFuture<Value>) -> EventLoopFuture<Value> {
        return self.flatMapError(file: file, line: line, callback)
    }

    @available(*, deprecated, renamed: "flatMapErrorThrowing")
    public func thenIfErrorThrowing(file: StaticString = #file, line: UInt = #line, _ callback: @escaping (Error) throws -> Value) -> EventLoopFuture<Value> {
        return self.flatMapErrorThrowing(file: file, line: line, callback)
    }
}

extension EventLoopGroup {
    @available(*, deprecated, message: "makeIterator is now required")
    public func makeIterator() -> NIO.EventLoopIterator {
        return .init([])
    }
}

extension MarkedCircularBuffer {
    @available(*, deprecated, message: "hasMark is now a property, remove `()`")
    public func hasMark() -> Bool {
        return self.hasMark
    }

    @available(*, deprecated, message: "markedElement is now a property, remove `()`")
    public func markedElement() -> Element? {
        return self.markedElement
    }

    @available(*, deprecated, message: "markedElementIndex is now a property, remove `()`")
    public func markedElementIndex() -> Int? {
        return self.markedElementIndex
    }
}

extension HTTPVersion {
    @available(*, deprecated, message: "type of major and minor is now Int")
    public init(major: UInt16, minor: UInt16) {
        self = .init(major: Int(major), minor: Int(minor))
    }

    @available(*, deprecated, message: "type of major is now Int")
    public var majorLegacy: UInt16 {
        return UInt16(self.major)
    }

    @available(*, deprecated, message: "type of minor is now Int")
    public var minorLegacy: UInt16 {
        return UInt16(self.minor)
    }
}

@available(*, deprecated, renamed: "ChannelError")
public enum ChannelLifecycleError {
    @available(*, deprecated, message: "ChannelLifecycleError values are now available on ChannelError")
    public static var inappropriateOperationForState: ChannelError {
        return ChannelError.inappropriateOperationForState
    }

}

@available(*, deprecated, renamed: "ChannelError")
public enum MulticastError {
    @available(*, deprecated, message: "MulticastError values are now available on ChannelError")
    public static var unknownLocalAddress: ChannelError {
        return .unknownLocalAddress
    }

    @available(*, deprecated, message: "MulticastError values are now available on ChannelError")
    public static var badMulticastGroupAddressFamily: ChannelError {
        return .badMulticastGroupAddressFamily
    }

    @available(*, deprecated, message: "MulticastError values are now available on ChannelError")
    public static var badInterfaceAddressFamily: ChannelError {
        return .badInterfaceAddressFamily
    }

    @available(*, deprecated, message: "MulticastError values are now available on ChannelError")
    public static func illegalMulticastAddress(_ address: SocketAddress) -> ChannelError {
        return .illegalMulticastAddress(address)
    }
}

extension ChannelError {
    @available(*, deprecated, message: "ChannelError.connectFailed has been removed")
    public static var connectFailed: NIOConnectionError {
        fatalError("ChannelError.connectFailed has been removed in NIO2")
    }
}


extension SocketAddress {
    @available(*, deprecated, message: "type of port is now Int?")
    public var portLegacy: UInt16? {
        return self.port.map(UInt16.init)
    }

    @available(*, deprecated, renamed: "makeAddressResolvingHost")
    public static func newAddressResolving(host: String, port: Int) throws -> SocketAddress {
        return try self.makeAddressResolvingHost(host, port: port)
    }
}
