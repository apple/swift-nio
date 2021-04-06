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

extension NIODeque: MutableCollection {
  /// Exchanges the values at the specified indices of the collection.
  ///
  /// Both parameters must be valid indices of the collection and not equal to
  /// `endIndex`. Passing the same index as both `i` and `j` has no effect.
  ///
  /// - Parameters:
  ///   - i: The index of the first value to swap.
  ///   - j: The index of the second value to swap.
  ///
  /// - Complexity: O(1) when this instance has a unique reference to its
  ///    underlying storage; O(`count`) otherwise.
  /* was @inlinable */
  @usableFromInline internal /*was public */ mutating func swapAt(_ i: Index, _ j: Index) {
    precondition(i >= 0 && i < count, "Index out of bounds")
    precondition(j >= 0 && j < count, "Index out of bounds")
    _storage.ensureUnique()
    _storage.update { handle in
      let slot1 = handle.slot(forOffset: i)
      let slot2 = handle.slot(forOffset: j)
      handle.mutableBuffer.swapAt(slot1.position, slot2.position)
    }
  }

  // FIXME: Implement `partition(by:)` by making storage contiguous,
  // and partitioning that.

  /// Call `body(b)`, where `b` is an unsafe buffer pointer to the deque's
  /// mutable contiguous storage. If the deque's contents aren't stored
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
  ///    underlying storage; O(`count`) otherwise. (Not counting the call to
  ///    `body`.)
  /* was @inlinable */
  @usableFromInline internal /*was public */ mutating func withContiguousMutableStorageIfAvailable<R>(
    _ body: (inout UnsafeMutableBufferPointer<Element>) throws -> R
  ) rethrows -> R? {
    _storage.ensureUnique()
    return try _storage.update { handle in
      let endSlot = handle.startSlot.advanced(by: handle.count)
      guard endSlot.position <= handle.capacity else {
        // FIXME: Rotate storage such that it becomes contiguous.
        return nil
      }
      let original = handle.mutableBuffer(for: handle.startSlot ..< endSlot)
      var extract = original
      defer {
        precondition(extract.baseAddress == original.baseAddress && extract.count == original.count,
                     "Closure must not replace the provided buffer")
      }
      return try body(&extract)
    }
  }

  /* was @inlinable */
  @usableFromInline internal /*was public */ mutating func _withUnsafeMutableBufferPointerIfSupported<R>(
    _ body: (inout UnsafeMutableBufferPointer<Element>) throws -> R
  ) rethrows -> R? {
    return try withContiguousMutableStorageIfAvailable(body)
  }
}
