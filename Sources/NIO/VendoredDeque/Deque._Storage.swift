/* Changes for SwiftNIO
   - renamed NIODeque to NIONIODeque (to prevent future clashes)
   - made (NIO)NIODeque internal (not public)

  DO NOT CHANGE THESE FILES, THEY ARE VENDORED FROM Swift Collections.
*/
//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Collections open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

extension NIODeque {
  @usableFromInline
  struct _Storage {
    @usableFromInline
    internal typealias _Buffer = ManagedBufferPointer<_NIODequeBufferHeader, Element>

    @usableFromInline
    internal var _buffer: _Buffer

    /* was @inlinable */
    @inline(__always)
    internal init(_buffer: _Buffer) {
      self._buffer = _buffer
    }
  }
}

extension NIODeque._Storage: CustomStringConvertible {
  @usableFromInline
  internal var description: String {
    "NIODeque<\(Element.self)>._Storage\(_buffer.header)"
  }
}

extension NIODeque._Storage {
  /* was @inlinable */
  internal init() {
    self.init(_buffer: _Buffer(unsafeBufferObject: _emptyNIODequeStorage))
  }

  /* was @inlinable */
  internal init(_ object: _NIODequeBuffer<Element>) {
    self.init(_buffer: _Buffer(unsafeBufferObject: object))
  }

  /* was @inlinable */
  internal init(minimumCapacity: Int) {
    let object = _NIODequeBuffer<Element>.create(
      minimumCapacity: minimumCapacity,
      makingHeaderWith: { object in
        _NIODequeBufferHeader(capacity: object.capacity, count: 0, startSlot: .zero)
      })
    self.init(_buffer: _Buffer(unsafeBufferObject: object))
  }
}

extension NIODeque._Storage {
  #if COLLECTIONS_INTERNAL_CHECKS
  @usableFromInline @inline(never) @_effects(releasenone)
  internal func _checkInvariants() {
    _buffer.withUnsafeMutablePointerToHeader { $0.pointee._checkInvariants() }
  }
  #else
  /* was @inlinable */ @inline(__always)
  internal func _checkInvariants() {}
  #endif // COLLECTIONS_INTERNAL_CHECKS
}

extension NIODeque._Storage {
  /* was @inlinable */
  @inline(__always)
  internal var identity: AnyObject { _buffer.buffer }


  /* was @inlinable */
  @inline(__always)
  internal var capacity: Int {
    _buffer.withUnsafeMutablePointerToHeader { $0.pointee.capacity }
  }

  /* was @inlinable */
  @inline(__always)
  internal var count: Int {
    _buffer.withUnsafeMutablePointerToHeader { $0.pointee.count }
  }

  /* was @inlinable */
  @inline(__always)
  internal var startSlot: _NIODequeSlot {
    _buffer.withUnsafeMutablePointerToHeader { $0.pointee.startSlot
    }
  }
}

extension NIODeque._Storage {
  @usableFromInline
  internal typealias Index = Int

  @usableFromInline
  internal typealias _UnsafeHandle = NIODeque._UnsafeHandle

  /* was @inlinable */
  @inline(__always)
  internal func read<R>(_ body: (_UnsafeHandle) throws -> R) rethrows -> R {
    try _buffer.withUnsafeMutablePointers { header, elements in
      let handle = _UnsafeHandle(header: header,
                                 elements: elements,
                                 isMutable: false)
      return try body(handle)
    }
  }

  /* was @inlinable */
  @inline(__always)
  internal func update<R>(_ body: (_UnsafeHandle) throws -> R) rethrows -> R {
    try _buffer.withUnsafeMutablePointers { header, elements in
      let handle = _UnsafeHandle(header: header,
                                 elements: elements,
                                 isMutable: true)
      return try body(handle)
    }
  }
}

extension NIODeque._Storage {
  /// Return a boolean indicating whether this storage instance is known to have
  /// a single unique reference. If this method returns true, then it is safe to
  /// perform in-place mutations on the deque.
  /* was @inlinable */
  @inline(__always)
  internal mutating func isUnique() -> Bool {
    _buffer.isUniqueReference()
  }

  /// Ensure that this storage refers to a uniquely held buffer by copying
  /// elements if necessary.
  /* was @inlinable */
  @inline(__always)
  internal mutating func ensureUnique() {
    if isUnique() { return }
    self._makeUniqueCopy()
  }

  /* was @inlinable */
  @inline(never)
  internal mutating func _makeUniqueCopy() {
    self = self.read { $0.copyElements() }
  }

  /// The growth factor to use to increase storage size to make place for an
  /// insertion.
  /* was @inlinable */
  @inline(__always)
  internal static var growthFactor: Double { 1.5 }

  @usableFromInline
  internal func _growCapacity(
    to minimumCapacity: Int,
    linearly: Bool
  ) -> Int {
    if linearly { return Swift.max(capacity, minimumCapacity) }
    return Swift.max(Int((Self.growthFactor * Double(capacity)).rounded(.up)),
                     minimumCapacity)
  }

  /// Ensure that we have a uniquely referenced buffer with enough space to
  /// store at least `minimumCapacity` elements.
  ///
  /// - Parameter minimumCapacity: The minimum number of elements the buffer
  ///    needs to be able to hold on return.
  ///
  /// - Parameter linearGrowth: If true, then don't use an exponential growth
  ///    factor when reallocating the buffer -- just allocate space for the
  ///    requested number of elements
  /* was @inlinable */
  @inline(__always)
  internal mutating func ensureUnique(
    minimumCapacity: Int,
    linearGrowth: Bool = false
  ) {
    let unique = isUnique()
    if _slowPath(capacity < minimumCapacity || !unique) {
      _ensureUnique(minimumCapacity: minimumCapacity, linearGrowth: linearGrowth)
    }
  }

  /* was @inlinable */
  internal mutating func _ensureUnique(
    minimumCapacity: Int,
    linearGrowth: Bool
  ) {
    if capacity >= minimumCapacity {
      assert(!self.isUnique())
      self = self.read { $0.copyElements() }
    } else if isUnique() {
      let minimumCapacity = _growCapacity(to: minimumCapacity, linearly: linearGrowth)
      self = self.update { source in
        source.moveElements(minimumCapacity: minimumCapacity)
      }
    } else {
      let minimumCapacity = _growCapacity(to: minimumCapacity, linearly: linearGrowth)
      self = self.read { source in
        source.copyElements(minimumCapacity: minimumCapacity)
      }
    }
  }
}
