//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// ``NIOLoopBound`` is an always-`Sendable`, value-typed container allowing you access to ``value`` if and only if
/// you are accessing it on the right ``EventLoop``.
///
/// ``NIOLoopBound`` is useful to transport a value of a non-`Sendable` type that needs to go from one place in
/// your code to another where you (but not the compiler) know is on one and the same ``EventLoop``. Usually this
/// involves `@Sendable` closures. This type is safe because it verifies (using ``EventLoop/preconditionInEventLoop(file:line:)-2fxvb``)
/// that this is actually true.
///
/// A ``NIOLoopBound`` can only be constructed, read from or written to when you are provably
/// (through ``EventLoop/preconditionInEventLoop(file:line:)-2fxvb``) on the ``EventLoop`` associated with the ``NIOLoopBound``. Accessing
/// or constructing it from any other place will crash your program with a precondition as it would be undefined
/// behaviour to do so.
public struct NIOLoopBound<Value>: @unchecked Sendable {
    /// The ``EventLoop`` that the value is bound to.
    public let eventLoop: EventLoop

    @available(*, deprecated, renamed: "eventLoop")
    public var _eventLoop: EventLoop {
        self.eventLoop
    }

    @usableFromInline
    var _value: Value

    /// Initialise a ``NIOLoopBound`` to `value` with the precondition that the code is running on `eventLoop`.
    @inlinable
    public init(_ value: Value, eventLoop: EventLoop) {
        eventLoop.preconditionInEventLoop()
        self.eventLoop = eventLoop
        self._value = value
    }

    /// Access the `value` with the precondition that the code is running on `eventLoop`.
    ///
    /// - Note: ``NIOLoopBound`` itself is value-typed, so any writes will only affect the current value.
    @inlinable
    public var value: Value {
        get {
            self.eventLoop.preconditionInEventLoop()
            return self._value
        }
        _modify {
            self.eventLoop.preconditionInEventLoop()
            yield &self._value
        }
    }
}

/// ``NIOLoopBoundBox`` is an always-`Sendable`, reference-typed container allowing you access to ``value`` if and
/// only if you are accessing it on the right ``EventLoop``.
///
/// ``NIOLoopBoundBox`` is useful to transport a value of a non-`Sendable` type that needs to go from one place in
/// your code to another where you (but not the compiler) know is on one and the same ``EventLoop``. Usually this
/// involves `@Sendable` closures. This type is safe because it verifies (using ``EventLoop/preconditionInEventLoop(file:line:)-7ukrq``)
/// that this is actually true.
///
/// A ``NIOLoopBoundBox`` can only be read from or written to when you are provably
/// (through ``EventLoop/preconditionInEventLoop(file:line:)-2fxvb``) on the ``EventLoop`` associated with the ``NIOLoopBoundBox``. Accessing
/// or constructing it from any other place will crash your program with a precondition as it would be undefined
/// behaviour to do so.
///
/// If constructing a ``NIOLoopBoundBox`` with a `value`, it is also required for the program to already be on `eventLoop`
/// but if you have a ``NIOLoopBoundBox`` that contains an `Optional` type, you may initialise it _without a value_
/// whilst off the ``EventLoop`` by using ``NIOLoopBoundBox/makeEmptyBox(valueType:eventLoop:)``. Any read/write access to ``value``
/// afterwards will require you to be on `eventLoop`.
public final class NIOLoopBoundBox<Value>: @unchecked Sendable {
    /// The ``EventLoop`` that the value is bound to.
    public let eventLoop: EventLoop

    @available(*, deprecated, renamed: "eventLoop")
    public var _eventLoop: EventLoop {
        self.eventLoop
    }

    @usableFromInline
    var _value: Value

    @inlinable
    internal init(_value value: Value, uncheckedEventLoop eventLoop: EventLoop) {
        self.eventLoop = eventLoop
        self._value = value
    }

    /// Initialise a ``NIOLoopBoundBox`` to `value` with the precondition that the code is running on `eventLoop`.
    @inlinable
    public convenience init(_ value: Value, eventLoop: EventLoop) {
        // This precondition is absolutely required. If not, it were possible to take a non-Sendable `Value` from
        // _off_ the ``EventLoop`` and transport it _to_ the ``EventLoop``. That would be illegal.
        eventLoop.preconditionInEventLoop()
        self.init(_value: value, uncheckedEventLoop: eventLoop)
    }

    /// Initialise a ``NIOLoopBoundBox`` that is empty (contains `nil`), this does _not_ require you to be running on `eventLoop`.
    public static func makeEmptyBox<NonOptionalValue>(
        valueType: NonOptionalValue.Type = NonOptionalValue.self,
        eventLoop: EventLoop
    ) -> NIOLoopBoundBox<Value> where NonOptionalValue? == Value {
        // Here, we -- possibly surprisingly -- do not precondition being on the EventLoop. This is okay for a few
        // reasons:
        // - We write the `Optional.none` value which we know is _not_ a value of the potentially non-Sendable type
        //   `Value`.
        // - Because of Swift's Definitive Initialisation (DI), we know that we did write `self._value` before `init`
        //   returns.
        // - The only way to ever write (or read indeed) `self._value` is by proving to be inside the `EventLoop`.
        .init(_value: nil, uncheckedEventLoop: eventLoop)
    }

    /// Initialise a ``NIOLoopBoundBox`` by sending a `Sendable` value, validly callable off `eventLoop`.
    ///
    /// Contrary to ``init(_:eventLoop:)``, this method can be called off `eventLoop` because we know that `value` is `Sendable`.
    /// So we don't need to protect `value` itself, we just need to protect the ``NIOLoopBoundBox`` against mutations which we do because the ``value``
    /// accessors are checking that we're on `eventLoop`.
    public static func makeBoxSendingValue(
        _ value: Value,
        as: Value.Type = Value.self,
        eventLoop: EventLoop
    ) -> NIOLoopBoundBox<Value> where Value: Sendable {
        // Here, we -- possibly surprisingly -- do not precondition being on the EventLoop. This is okay for a few
        // reasons:
        // - This function only works with `Sendable` values, so we don't need to worry about somebody
        //   still holding a reference to this.
        // - Because of Swift's Definitive Initialisation (DI), we know that we did write `self._value` before `init`
        //   returns.
        // - The only way to ever write (or read indeed) `self._value` is by proving to be inside the `EventLoop`.
        .init(_value: value, uncheckedEventLoop: eventLoop)
    }

    /// Initialise a ``NIOLoopBoundBox`` by sending a  value, validly callable off `eventLoop`.
    ///
    /// Contrary to ``init(_:eventLoop:)``, this method can be called off `eventLoop` because `value` is moved into the box and can no longer be accessed outside the box.
    /// So we don't need to protect `value` itself, we just need to protect the ``NIOLoopBoundBox`` against mutations which we do because the ``value``
    /// accessors are checking that we're on `eventLoop`.
    public static func makeBoxSendingValue(
        _ value: sending Value,
        as: Value.Type = Value.self,
        eventLoop: EventLoop
    ) -> NIOLoopBoundBox<Value> {
        // Here, we -- possibly surprisingly -- do not precondition being on the EventLoop. This is okay for a few
        // reasons:
        // - This function takes its value as `sending` so we don't need to worry about somebody
        //   still holding a reference to this.
        // - Because of Swift's Definitive Initialisation (DI), we know that we did write `self._value` before `init`
        //   returns.
        // - The only way to ever write (or read indeed) `self._value` is by proving to be inside the `EventLoop`.
        .init(_value: value, uncheckedEventLoop: eventLoop)
    }

    /// Access the `value` with the precondition that the code is running on `eventLoop`.
    ///
    /// - Note: ``NIOLoopBoundBox`` itself is reference-typed, so any writes will affect anybody sharing this reference.
    @inlinable
    public var value: Value {
        get {
            self.eventLoop.preconditionInEventLoop()
            return self._value
        }
        _modify {
            self.eventLoop.preconditionInEventLoop()
            yield &self._value
        }
    }

    /// Safely access and potentially modify the contained value with a closure.
    ///
    /// This method provides a way to perform operations on the contained value while ensuring
    /// thread safety through EventLoop verification. The closure receives an `inout` parameter
    /// allowing both read and write access to the value.
    ///
    /// - Parameter handler: A closure that receives an `inout` reference to the contained value.
    ///   The closure can read from and write to this value. Any modifications made within the
    ///   closure will be reflected in the box after the closure completes, even if the closure throws.
    /// - Returns: The value returned by the `handler` closure.
    /// - Note: This method is particularly useful when you need to perform read and write operations
    ///         on the value because it reduces the on EventLoop checks.
    @inlinable
    public func withValue<Success, Failure: Error>(
        _ handler: (inout Value) throws(Failure) -> Success
    ) throws(Failure) -> Success {
        self.eventLoop.preconditionInEventLoop()
        return try handler(&self._value)
    }
}
