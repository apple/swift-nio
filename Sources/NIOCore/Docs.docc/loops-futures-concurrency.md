# EventLoops, EventLoopFutures, and Swift Concurrency

This article aims to communicate how NIO's ``EventLoop``s and ``EventLoopFuture``s interact with the Swift 6
concurrency model, particularly regarding data-race safety. It aims to be a reference for writing correct
concurrent code in the NIO model.

NIO predates the Swift concurrency model. As a result, several of NIO's concepts are not perfect matches to
the concepts that Swift uses, or have overlapping responsibilities.

## Isolation domains and executors

First, a quick recap. The core of Swift 6's data-race safety protection is the concept of an "isolation
domain". Some valuable reading regarding the concept can be found in
[SE-0414 (Region based isolation)](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0414-region-based-isolation.md)
but at a high level an isolation domain can be understood to be a collection of state and methods within which there cannot be
multiple executors executing code at the same time.

In standard Swift Concurrency, the main boundaries of isolation domains are actors and tasks. Each actor,
including global actors, defines an isolation domain. Additionally, for functions and methods that are
not isolated to an actor, the `Task` within which that code executes defines an isolation domain. Passing
values between these isolation domains requires that these values are either `Sendable` (safe to hold in
multiple domains), or that the `sending` keyword is used to force the value to be passed from one domain
to another.

A related concept to an "isolation domain" is an "executor". Again, useful reading can be found in
[SE-0392 (Custom actor executors)](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md).
At a high level, an executor is simply an object that is capable of executing Swift `Task`s. Executors can be
concurrent, or they can be serial. Serial executors are the most common, as they can be used to back an
actor.

## Event Loops

NIO's core execution primitive is the ``EventLoop``. An ``EventLoop`` is fundamentally nothing more than
a Swift Concurrency Serial Executor that can also perform I/O operations directly. Indeed, NIO's
``EventLoop``s can be exposed as serial executors, using ``EventLoop/executor``. This provides a mechanism
to protect actor-isolated state using a NIO event-loop. With [the introduction of task executors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0417-task-executor-preference.md),
future versions of SwiftNIO will also be able to offer their event loops for individual `Task`s to execute
on as well.

In a Swift 6 world, it is possible that these would be the API that NIO offered to execute tasks on the
loop. However, as NIO predates Swift 6, it also offers its own set of APIs to enqueue work. This includes
(but is not limited to):

- ``EventLoop/execute(_:)``
- ``EventLoop/submit(_:)``
- ``EventLoop/scheduleTask(in:_:)``
- ``EventLoop/scheduleRepeatedTask(initialDelay:delay:notifying:_:)``
- ``EventLoop/scheduleCallback(at:handler:)-2xm6l``

The existence of these APIs requires us to also ask the question of where the submitted code executes. The
answer is that the submitted code executes on the event loop (or, in Swift Concurrency terms, on the
executor provided by the event loop).

As the event loop only ever executes a single item of work (either an `async` function or one of the
closures above) at a time, it is a _serial_ executor. It also provides an _isolation domain_: code
submitted to a given `EventLoop` never runs in parallel with other code submitted to the same loop.

The result here is that a all closures passed into the event loop to do work must be transferred
in: they may not be kept hold of outside of the event loop. That means they must be sent using
the `sending` keyword.

> Note: As of the current 2.75.0 release, NIO enforces the stricter requirement that these closures
    are `@Sendable`. This is not a long-term position, but reflects the need to continue
    to support Swift 5 code which requires this stricter standard. In a future release of
    SwiftNIO we expect to relax this constraint: if you need this relaxed constraint
    then please file an issue.

## Event loop futures

In Swift NIO the most common mechanism to arrange a series of asynchronous work items is
_not_ to queue up a series of ``EventLoop/execute(_:)`` calls. Instead, users typically
use ``EventLoopFuture``.

``EventLoopFuture`` has some extensive semantics documented in its API documentation. The
most important principal for this discussion is that all callbacks added to an
``EventLoopFuture`` will execute on the ``EventLoop`` to which that ``EventLoopFuture`` is
bound. By extension, then, all callbacks added to an ``EventLoopFuture`` execute on the same
executor (the ``EventLoop``) in the same isolation domain.

The analogy to an actor here is hopefully fairly clear. Conceptually, an ``EventLoopFuture``
could be modelled as an actor. That means all the callbacks have the same logical semantics:
the ``EventLoopFuture`` uses the isolation domain of its associated ``EventLoop``, and all
the callbacks are `sent` into the isolation domain. To that end, all the callback-taking APIs
require that the callback is sent using `sending` into the ``EventLoopFuture``.

> Note: As of the current 2.75.0 release, NIO enforces the stricter requirement that these callbacks
    are `@Sendable`. This is not a long-term position, but reflects the need to continue
    to support Swift 5 code which requires this stricter standard. In a future release of
    SwiftNIO we expect to relax this constraint: if you need this relaxed constraint
    then please file an issue.

Unlike ``EventLoop``s, however, ``EventLoopFuture``s also have value-receiving and value-taking
APIs. This is because ``EventLoopFuture``s pass a value along to their various callbacks, and
so need to be both given an initial value (via an ``EventLoopPromise``) and in some cases to
extract that value from the ``EventLoopFuture`` wrapper.

This implies that ``EventLoopPromise``'s various success functions
(_and_ ``EventLoop/makeSucceededFuture(_:)``) need to take their value as `sending`. The value
is potentially sent from its current isolation domain into the ``EventLoop``, which will require
that the value is safe to move.

> Note: As of the current 2.75.0 release, NIO enforces the stricter requirement that these values
    are `Sendable`. This is not a long-term position, but reflects the need to continue
    to support Swift 5 code which requires this stricter standard. In a future release of
    SwiftNIO we expect to relax this constraint: if you need this relaxed constraint
    then please file an issue.

There are also a few ways to extract a value, such as ``EventLoopFuture/wait(file:line:)``
and ``EventLoopFuture/get()``. These APIs can only safely be called when the ``EventLoopFuture``
is carrying a `Sendable` value. This is because ``EventLoopFuture``s hold on to their value and
can give it to other closures or other callers of `get` and `wait`. Thus, `sending` is not
sufficient.

## Combining Futures

NIO provides a number of APIs for combining futures, such as ``EventLoopFuture/and(_:)``.
This potentially represents an issue, as two futures may not share the same isolation domain.
As a result, we can only safely call these combining functions when the ``EventLoopFuture``
values are `Sendable`.

> Note: We can conceptually relax this constraint somewhat by offering equivalent
    functions that can only safely be called when all the combined futures share the
    same bound event loop: that is, when they are all within the same isolation domain.

    This can be enforced with runtime isolation checks. If you have a need for these
    functions, please reach out to the NIO team.

## Interacting with Futures on the Event Loop

In a number of contexts (such as in ``ChannelHandler``s), the programmer has static knowledge
that they are within an isolation domain. That isolation domain may well be shared with the
isolation domain of many futures and promises with which they interact. For example,
futures that are provided from ``ChannelHandlerContext/write(_:promise:)`` will be bound to
the event loop on which the ``ChannelHandler`` resides.

In this context, the `sending` constraint is unnecessarily strict. The future callbacks are
guaranteed to fire on the same isolation domain as the ``ChannelHandlerContext``: no risk
of data race is present. However, Swift Concurrency cannot guarantee this at compile time,
as the specific isolation domain is determined only at runtime.

In these contexts, users that cannot require NIO 2.77.0 can make their callbacks
safe using ``NIOLoopBound`` and ``NIOLoopBoundBox``. These values can only be
constructed on the event loop, and only allow access to their values on the same
event loop. These constraints are enforced at runtime, so at compile time these are
unconditionally `Sendable`.

> Warning: ``NIOLoopBound`` and ``NIOLoopBoundBox`` replace compile-time isolation checks
    with runtime ones. This makes it possible to introduce crashes in your code. Please
    ensure that you are 100% confident that the isolation domains align. If you are not
    sure that the ``EventLoopFuture`` you wish to attach a callback to is bound to your
    ``EventLoop``, use ``EventLoopFuture/hop(to:)`` to move it to your isolation domain
    before using these types.

From NIO 2.77.0, new types were introduced to make this common problem easier. These types are
``EventLoopFuture/Isolated`` and ``EventLoopPromise/Isolated``. These isolated view types
can only be constructed from an existing Future or Promise, and they can only be constructed
on the ``EventLoop`` to which those futures or promises are bound. Because they are not
`Sendable`, we can be confident that these values never escape the isolation domain in which
they are created, which must be the same isolation domain where the callbacks execute.

As a result, these types can drop the `@Sendable` requirements on all the future closures, and
many of the `Sendable` requirements on the return types from future closures. They can also
drop the `Sendable` requirements from the promise completion functions.

These isolated views can be obtained by calling ``EventLoopFuture/assumeIsolated()`` or
``EventLoopPromise/assumeIsolated()``.

> Warning: ``EventLoopFuture/assumeIsolated()`` and ``EventLoopPromise/assumeIsolated()``
    supplement compile-time isolation checks with runtime ones. This makes it possible
    to introduce crashes in your code. Please ensure that you are 100% confident that the
    isolation domains align. If you are not sure that the ``EventLoopFuture`` or
    ``EventLoopPromise`` you wish to attach a callback to is bound to your
    ``EventLoop``, use ``EventLoopFuture/hop(to:)`` to move it to your isolation domain
    before using these types.

> Warning: ``EventLoopFuture/assumeIsolated()`` and ``EventLoopPromise/assumeIsolated()``
    **must not** be called from a Swift concurrency context, either an async method or
    from within an actor. This is because it uses runtime checking of the event loop
    to confirm that the value is not being sent to a different concurrency domain.
    
    When using an ``EventLoop`` as a custom actor executor, this API can be used to retrieve
    a value that region based isolation will then allow to be sent to another domain.

## Interacting with Event Loops on the Event Loop

As with Futures, there are occasionally times where it is necessary to schedule
``EventLoop`` operations on the ``EventLoop`` where your code is currently executing.

Much like with ``EventLoopFuture``, if you need to support NIO versions before 2.77.0
you can use ``NIOLoopBound`` and ``NIOLoopBoundBox`` to make these callbacks safe.

> Warning: ``NIOLoopBound`` and ``NIOLoopBoundBox`` replace compile-time isolation checks
    with runtime ones. This makes it possible to introduce crashes in your code. Please
    ensure that you are 100% confident that the isolation domains align. If you are not
    sure that the ``EventLoopFuture`` you wish to attach a callback to is bound to your
    ``EventLoop``, use ``EventLoopFuture/hop(to:)`` to move it to your isolation domain
    before using these types.

From NIO 2.77.0, a new type was introduced to make this common problem easier. This type is
``NIOIsolatedEventLoop``. This isolated view type can only be constructed from an existing
``EventLoop``, and it can only be constructed on the ``EventLoop`` that is being wrapped.
Because this type is not `Sendable`, we can be confident that this value never escapes the
isolation domain in which it was created, which must be the same isolation domain where the
callbacks execute.

As a result, this type can drop the `@Sendable` requirements on all the operation closures, and
many of the `Sendable` requirements on the return types from these closures.

This isolated view can be obtained by calling ``EventLoop/assumeIsolated()``.

> Warning: ``EventLoop/assumeIsolated()`` supplements compile-time isolation checks with
    runtime ones. This makes it possible to introduce crashes in your code. Please ensure
    that you are 100% confident that the isolation domains align. If you are not sure that
    the your code is running on the relevant ``EventLoop``, prefer the non-isolated type.

> Warning: ``EventLoop/assumeIsolated()`` **must not** be called from a Swift concurrency
    context, either an async method or from within an actor. This is because it uses runtime
    checking of the event loop to confirm that the value is not being sent to a different
    concurrency domain.
    
    When using an ``EventLoop`` as a custom actor executor, this API can be used to retrieve
    a value that region based isolation will then allow to be sent to another domain.
