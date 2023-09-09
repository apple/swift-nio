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
    public let _eventLoop: EventLoop

    @usableFromInline
    /* private */ var _value: Value

    /// Initialize a ``NIOLoopBound`` to `value` with the precondition that the code is running on `eventLoop`.
    @inlinable
    public init(_ value: Value, eventLoop: EventLoop) {
        eventLoop.preconditionInEventLoop()
        self.init(value, uncheckedEventLoop: eventLoop)
    }

    @inlinable
    /// Initialize a ``NIOLoopBound`` to `value` with _an assertion_ that the code is running on `uncheckedEventLoop`.
    /// Unlike a precondition check,  ``EventLoop/assertInEventLoop(file:line:)`` only performs the check in debug configuration, so the check is free in release configuration.
    public init(_ value: Value, uncheckedEventLoop eventLoop: EventLoop) {
        eventLoop.assertInEventLoop()
        self._eventLoop = eventLoop
        self._value = value
    }

    /// Access the `value` with the precondition that the code is running on `eventLoop`.
    ///
    /// - note: ``NIOLoopBound`` itself is value-typed, so any writes will only affect the current value.
    @inlinable
    public var value: Value {
        get {
            self._eventLoop.preconditionInEventLoop()
            return self._value
        }
        set {
            self._eventLoop.preconditionInEventLoop()
            self._value = newValue
        }
    }

    /// Access the `value` with the assertion that the code is running on `eventLoop`.
    ///
    /// Unlike ``NIOLoopBound/value``, this performs the assertion in debug configuration only, so it's
    /// cheaper, and still performs the precondition check in debug mode.
    /// - note: ``NIOLoopBound`` itself is value-typed, so any writes will only affect the current value.
    @inlinable
    public var uncheckedValue: Value {
        get {
            self._eventLoop.assertInEventLoop()
            return self._value
        }
        set {
            self._eventLoop.assertInEventLoop()
            self._value = newValue
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
    public let _eventLoop: EventLoop

    @usableFromInline
    /* private */var _value: Value

    /// Initialize a ``NIOLoopBoundBox`` to `value` with the an assertion that the code is running on `eventLoop`.
    ///
    /// - note: Unlike ``NIOLoopBoundBox/init(_:eventLoop:)``, this performs ``EventLoop/assertInEventLoop(file:line:)`` instead of a precondition check, which is free in release mode.
    @inlinable
    public init(_ value: Value, uncheckedEventLoop eventLoop: EventLoop) {
        eventLoop.assertInEventLoop()
        self._eventLoop = eventLoop
        self._value = value
    }

    @inlinable
    internal init(_ value: Value, notVerifyingEventLoop eventLoop: EventLoop) {
        self._eventLoop = eventLoop
        self._value = value
    }

    /// Initialize a ``NIOLoopBoundBox`` to `value` with the precondition that the code is running on `eventLoop`.
    @inlinable
    public convenience init(_ value: Value, eventLoop: EventLoop) {
        // This precondition is absolutely required. If not, it were possible to take a non-Sendable `Value` from
        // _off_ the ``EventLoop`` and transport it _to_ the ``EventLoop``. That would be illegal.
        eventLoop.preconditionInEventLoop()
        self.init(value, uncheckedEventLoop: eventLoop)
    }

    /// Initialise a ``NIOLoopBoundBox`` that is empty (contains `nil`), this does _not_ require you to be running on `eventLoop`.
    public static func makeEmptyBox<NonOptionalValue>(
        valueType: NonOptionalValue.Type = NonOptionalValue.self,
        eventLoop: EventLoop
    ) -> NIOLoopBoundBox<Value> where Optional<NonOptionalValue> == Value {
        // Here, we -- possibly surprisingly -- do not precondition being on the EventLoop. This is okay for a few
        // reasons:
        // - We write the `Optional.none` value which we know is _not_ a value of the potentially non-Sendable type
        //   `Value`.
        // - Because of Swift's Definitive Initialisation (DI), we know that we did write `self._value` before `init`
        //   returns.
        // - The only way to ever write (or read indeed) `self._value` is by proving to be inside the `EventLoop`.
        return .init(nil, notVerifyingEventLoop: eventLoop)
    }

    /// Access the `value` with the precondition that the code is running on `eventLoop`.
    ///
    /// - note: ``NIOLoopBoundBox`` itself is reference-typed, so any writes will affect anybody sharing this reference.
    @inlinable
    public var value: Value {
        get {
            self._eventLoop.preconditionInEventLoop()
            return self._value
        }
        set {
            self._eventLoop.preconditionInEventLoop()
            self._value = newValue
        }
    }

    /// Access the `value` with the assertion that the code is running on `eventLoop`.
    ///
    /// - note: ``NIOLoopBoundBox`` itself is reference-typed, so any writes will affect anybody sharing this reference.
    @inlinable
    public var uncheckedValue: Value {
        get {
            self._eventLoop.assertInEventLoop()
            return self._value
        }
        set {
            self._eventLoop.assertInEventLoop()
            self._value = newValue
        }
    }

  
}

