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

extension NIODeque: Sequence {
  // Implementation note: we could also use the default `IndexingIterator` here.
  // This custom implementation performs direct storage access to eliminate any
  // and all index validation overhead. It also optimizes away repeated
  // conversions from indices to storage slots.

  /// An iterator over the members of a deque.
  @usableFromInline internal /*was public */ struct Iterator: IteratorProtocol {
    @usableFromInline
    internal var _storage: NIODeque._Storage

    @usableFromInline
    internal var _nextSlot: _Slot

    @usableFromInline
    internal var _endSlot: _Slot

    /* was @inlinable */
    internal init(_storage: NIODeque._Storage, start: _Slot, end: _Slot) {
      self._storage = _storage
      self._nextSlot = start
      self._endSlot = end
    }

    /* was @inlinable */
    internal init(_base: NIODeque) {
      self = _base._storage.read { handle in
        let start = handle.startSlot
        let end = Swift.min(start.advanced(by: handle.count), handle.limSlot)
        return Self(_storage: _base._storage, start: start, end: end)
      }
    }

    /* was @inlinable */
    internal init(_base: NIODeque, from index: Index) {
      assert(index <= _base.count)
      self = _base._storage.read { handle in
        let start = handle.slot(forOffset: index)
        if index == _base.count {
          return Self(_storage: _base._storage, start: start, end: start)
        }
        var end = handle.endSlot
        if start >= end { end = handle.limSlot }
        return Self(_storage: _base._storage, start: start, end: end)
      }
    }

    /* was @inlinable */
    @inline(never)
    internal mutating func _swapSegment() -> Bool {
      assert(_nextSlot == _endSlot)
      return _storage.read { handle in
        let end = handle.endSlot
        if end == .zero || end == _nextSlot {
          return false
        }
        _endSlot = end
        _nextSlot = .zero
        return true
      }
    }

    /// Advances to the next element and returns it, or `nil` if no next element
    /// exists.
    ///
    /// Once `nil` has been returned, all subsequent calls return `nil`.
    /* was @inlinable */
    @usableFromInline internal /*was public */ mutating func next() -> Element? {
      if _nextSlot == _endSlot {
        guard _swapSegment() else { return nil }
      }
      assert(_nextSlot < _endSlot)
      let slot = _nextSlot
      _nextSlot = _nextSlot.advanced(by: 1)
      return _storage.read { handle in
        return handle.ptr(at: slot).pointee
      }
    }
  }

  /// Returns an iterator over the elements of the deque.
  ///
  /// - Complexity: O(1)
  /* was @inlinable */
  @usableFromInline internal /*was public */ func makeIterator() -> Iterator {
    Iterator(_base: self)
  }

  /* was @inlinable */
  @usableFromInline internal /*was public */ __consuming func _copyToContiguousArray() -> ContiguousArray<Element> {
    ContiguousArray(unsafeUninitializedCapacity: count) { target, count in
      _storage.read { source in
        let segments = source.segments()
        let c = segments.first.count
        target[..<c]._rebased()._initialize(from: segments.first)
        count += segments.first.count
        if let second = segments.second {
          target[c ..< c + second.count]._rebased()._initialize(from: second)
          count += second.count
        }
        assert(count == self.count)
      }
    }
  }

  /* was @inlinable */
  @usableFromInline internal /*was public */ __consuming func _copyContents(
    initializing target: UnsafeMutableBufferPointer<Element>
  ) -> (Iterator, UnsafeMutableBufferPointer<Element>.Index) {
    _storage.read { source in
      let segments = source.segments()
      let c1 = Swift.min(segments.first.count, target.count)
      target[..<c1]._rebased()._initialize(from: segments.first.prefix(c1)._rebased())
      guard target.count > c1, let second = segments.second else {
        return (Iterator(_base: self, from: c1), c1)
      }
      let c2 = Swift.min(second.count, target.count - c1)
      target[c1 ..< c1 + c2]._rebased()._initialize(from: second.prefix(c2)._rebased())
      return (Iterator(_base: self, from: c1 + c2), c1 + c2)
    }
  }

  /// Call `body(b)`, where `b` is an unsafe buffer pointer to the deque's
  /// contiguous storage, if available. If the deque's contents aren't stored
  /// contiguously, `body` is not called and `nil` is returned. The supplied
  /// buffer pointer is only valid for the duration of the call.
  ///
  /// Often, the optimizer can eliminate bounds- and uniqueness-checks within an
  /// algorithm, but when that fails, invoking the same algorithm on the unsafe
  /// buffer supplied to `body` lets you trade safety for speed.
  ///
  /// - Parameters:
  ///   - body: The function to invoke.
  ///
  /// - Returns: The value returned by `body`, or `nil` if `body` wasn't called.
  ///
  /// - Complexity: O(1) when this instance has a unique reference to its
  ///    underlying storage; O(`count`) otherwise.
  /* was @inlinable */
  @usableFromInline internal /*was public */ func withContiguousStorageIfAvailable<R>(
    _ body: (UnsafeBufferPointer<Element>) throws -> R
  ) rethrows -> R? {
    return try _storage.read { handle in
      let endSlot = handle.startSlot.advanced(by: handle.count)
      guard endSlot.position <= handle.capacity else { return nil }
      return try body(handle.buffer(for: handle.startSlot ..< endSlot))
    }
  }
}
