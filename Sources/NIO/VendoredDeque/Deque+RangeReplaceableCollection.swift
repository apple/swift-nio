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

extension NIODeque: RangeReplaceableCollection {
  /// Creates a new, empty deque.
  ///
  /// This is equivalent to initializing with an empty array literal.
  /// For example:
  ///
  ///     let deque1 = NIODeque<Int>()
  ///     print(deque1.isEmpty) // true
  ///
  ///     let deque2: NIODeque<Int> = []
  ///     print(deque2.isEmpty) // true
  ///
  /// - Complexity: O(1)
  /* was @inlinable */
  @usableFromInline internal /*was public */ init() {
    _storage = _Storage()
  }

  /// Replaces a range of elements with the elements in the specified
  /// collection.
  ///
  /// This method has the effect of removing the specified range of elements
  /// from the deque and inserting the new elements at the same location. The
  /// number of new elements need not match the number of elements being
  /// removed.
  ///
  /// - Parameters:
  ///   - subrange: The subrange of the deque to replace. The bounds of the
  ///      subrange must be valid indices of the deque (including the
  ///      `endIndex`).
  ///   - newElements: The new elements to add to the deque.
  ///
  /// - Complexity: O(`self.count + newElements.count`). If the operation needs
  ///    to change the size of the deque, it minimizes the number of existing
  ///    items that need to be moved by shifting elements either before or after
  ///    `subrange`.
  /* was @inlinable */
  @usableFromInline internal /*was public */ mutating func replaceSubrange<C: Collection>(
    _ subrange: Range<Index>,
    with newElements: __owned C
  ) where C.Element == Element {
    precondition(subrange.lowerBound >= 0 && subrange.upperBound <= count, "Index range out of bounds")
    let removalCount = subrange.count
    let insertionCount = newElements.count
    let deltaCount = insertionCount - removalCount
    _storage.ensureUnique(minimumCapacity: count + deltaCount)

    let replacementCount = Swift.min(removalCount, insertionCount)
    let targetCut = subrange.lowerBound + replacementCount
    let sourceCut = newElements.index(newElements.startIndex, offsetBy: replacementCount)

    _storage.update { target in
      target.uncheckedReplaceInPlace(
        inOffsets: subrange.lowerBound ..< targetCut,
        with: newElements[..<sourceCut])
      if deltaCount < 0 {
        let r = targetCut ..< subrange.upperBound
        assert(replacementCount + r.count == removalCount)
        target.uncheckedRemove(offsets: r)
      } else if deltaCount > 0 {
        target.uncheckedInsert(
          contentsOf: newElements[sourceCut...],
          count: deltaCount,
          atOffset: targetCut)
      }
    }
  }

  /// Reserves enough space to store the specified number of elements.
  ///
  /// If you are adding a known number of elements to a deque, use this method
  /// to avoid multiple reallocations. It ensures that the deque has unique
  /// storage, with space allocated for at least the requested number of
  /// elements.
  ///
  /// - Parameters:
  ///   - minimumCapacity: The requested number of elements to store.
  ///
  /// - Complexity: O(`count`)
  /* was @inlinable */
  @usableFromInline internal /*was public */ mutating func reserveCapacity(_ minimumCapacity: Int) {
    _storage.ensureUnique(minimumCapacity: minimumCapacity, linearGrowth: true)
  }

  /// Creates a new deque containing the specified number of a single, repeated
  /// value.
  ///
  /// - Parameters:
  ///   - repeatedValue: The element to repeat.
  ///   - count: The number of times to repeat the element. `count` must be zero
  ///      or greater.
  ///
  /// - Complexity: O(`count`)
  /* was @inlinable */
  @usableFromInline internal /*was public */ init(repeating repeatedValue: Element, count: Int) {
    precondition(count >= 0)
    self.init(minimumCapacity: count)
    _storage.update { handle in
      assert(handle.startSlot == .zero)
      if count > 0 {
        handle.ptr(at: .zero).initialize(repeating: repeatedValue, count: count)
      }
      handle.count = count
    }
  }

  /// Creates a deque containing the elements of a sequence.
  ///
  /// - Parameters:
  ///   - elements: The sequence of elements to turn into a deque.
  ///
  /// - Complexity: O(*n*), where *n* is the number of elements in the sequence.
  /* was @inlinable */
  @usableFromInline internal /*was public */ init<S: Sequence>(_ elements: S) where S.Element == Element {
    self.init()
    self.append(contentsOf: elements)
  }

  /// Creates a deque containing the elements of a collection.
  ///
  /// - Parameters:
  ///   - elements: The collection of elements to turn into a deque.
  ///
  /// - Complexity: O(`elements.count`)
  /* was @inlinable */
  @usableFromInline internal /*was public */ init<C: Collection>(_ elements: C) where C.Element == Element {
    let c = elements.count
    guard c > 0 else { _storage = _Storage(); return }
    self._storage = _Storage(minimumCapacity: c)
    _storage.update { handle in
      assert(handle.startSlot == .zero)
      let target = handle.mutableBuffer(for: .zero ..< _Slot(at: c))
      let done: Void? = elements.withContiguousStorageIfAvailable { source in
        target._initialize(from: source)
      }
      if done == nil {
        target._initialize(from: elements)
      }
      handle.count = c
    }
  }

  /// Adds a new element at the end of the deque.
  ///
  /// Use this method to append a single element to the end of a deque.
  ///
  ///     var numbers: NIODeque = [1, 2, 3, 4, 5]
  ///     numbers.append(100)
  ///     print(numbers)
  ///     // Prints "[1, 2, 3, 4, 5, 100]"
  ///
  /// Because deques increase their allocated capacity using an exponential
  /// strategy, appending a single element to a deque is an O(1) operation when
  /// averaged over many calls to the `append(_:)` method. When a deque has
  /// additional capacity and is not sharing its storage with another instance,
  /// appending an element is O(1). When a deque needs to reallocate storage
  /// before prepending or its storage is shared with another copy, appending is
  /// O(`count`).
  ///
  /// - Parameters:
  ///   - newElement: The element to append to the deque.
  ///
  /// - Complexity: Amortized O(1)
  ///
  /// - SeeAlso: `prepend(_:)`
  /* was @inlinable */
  @usableFromInline internal /*was public */ mutating func append(_ newElement: Element) {
    _storage.ensureUnique(minimumCapacity: count + 1)
    _storage.update {
      $0.uncheckedAppend(newElement)
    }
  }

  /// Adds the elements of a sequence to the end of the deque.
  ///
  /// Use this method to append the elements of a sequence to the front of this
  /// deque. This example appends the elements of a `Range<Int>` instance to a
  /// deque of integers.
  ///
  ///     var numbers: NIODeque = [1, 2, 3, 4, 5]
  ///     numbers.append(contentsOf: 10...15)
  ///     print(numbers)
  ///     // Prints "[1, 2, 3, 4, 5, 10, 11, 12, 13, 14, 15]"
  ///
  /// - Parameter newElements: The elements to append to the deque.
  ///
  /// - Complexity: Amortized O(`newElements.count`).
  /* was @inlinable */
  @usableFromInline internal /*was public */ mutating func append<S: Sequence>(contentsOf newElements: S) where S.Element == Element {
    let done: Void? = newElements.withContiguousStorageIfAvailable { source in
      _storage.ensureUnique(minimumCapacity: count + source.count)
      _storage.update { $0.uncheckedAppend(contentsOf: source) }
    }
    if done != nil {
      return
    }

    let underestimatedCount = newElements.underestimatedCount
    reserveCapacity(count + underestimatedCount)
    var it: S.Iterator = _storage.update { target in
      let gaps = target.availableSegments()
      let (it, copied) = gaps.initialize(fromSequencePrefix: newElements)
      target.count += copied
      return it
    }
    while let next = it.next() {
      _storage.ensureUnique(minimumCapacity: count + 1)
      _storage.update { target in
        target.uncheckedAppend(next)
        let gaps = target.availableSegments()
        target.count += gaps.initialize(fromPrefixOf: &it)
      }
    }
  }

  /// Adds the elements of a collection to the end of the deque.
  ///
  /// Use this method to append the elements of a collection to the front of
  /// this deque. This example appends the elements of a `Range<Int>` instance
  /// to a deque of integers.
  ///
  ///     var numbers: NIODeque = [1, 2, 3, 4, 5]
  ///     numbers.append(contentsOf: 10...15)
  ///     print(numbers)
  ///     // Prints "[1, 2, 3, 4, 5, 10, 11, 12, 13, 14, 15]"
  ///
  /// - Parameter newElements: The elements to append to the deque.
  ///
  /// - Complexity: Amortized O(`newElements.count`).
  /* was @inlinable */
  @usableFromInline internal /*was public */ mutating func append<C: Collection>(contentsOf newElements: C) where C.Element == Element {
    let done: Void? = newElements.withContiguousStorageIfAvailable { source in
      _storage.ensureUnique(minimumCapacity: count + source.count)
      _storage.update { $0.uncheckedAppend(contentsOf: source) }
    }
    guard done == nil else { return }

    let c = newElements.count
    guard c > 0 else { return }
    reserveCapacity(count + c)
    _storage.update { target in
      let gaps = target.availableSegments().prefix(c)
      gaps.initialize(from: newElements)
      target.count += c
    }
  }

  /// Inserts a new element at the specified position.
  ///
  /// The new element is inserted before the element currently at the specified
  /// index. If you pass the deque’s `endIndex` as the `index` parameter, the
  /// new element is appended to the deque.
  ///
  /// - Parameters:
  ///   - newElement: The new element to insert into the deque.
  ///   - index: The position at which to insert the new element. `index` must
  ///      be a valid index of the deque (including `endIndex`).
  ///
  /// - Complexity: O(`count`). The operation shifts existing elements either
  ///    towards the beginning or the end of the deque to minimize the number of
  ///    elements that need to be moved. When inserting at the start or the end,
  ///    this reduces the complexity to amortized O(1).
  /* was @inlinable */
  @usableFromInline internal /*was public */ mutating func insert(_ newElement: Element, at index: Index) {
    precondition(index >= 0 && index <= count,
                 "Can't insert element at invalid index")
    _storage.ensureUnique(minimumCapacity: count + 1)
    _storage.update { target in
      if index == 0 {
        target.uncheckedPrepend(newElement)
        return
      }
      if index == count {
        target.uncheckedAppend(newElement)
        return
      }
      let gap = target.openGap(ofSize: 1, atOffset: index)
      assert(gap.first.count == 1)
      gap.first.baseAddress!.initialize(to: newElement)
    }
  }

  /// Inserts the elements of a collection into the deque at the specified
  /// position.
  ///
  /// The new elements are inserted before the element currently at the
  /// specified index. If you pass the deque's `endIndex` property as the
  /// `index` parameter, the new elements are appended to the deque.
  ///
  /// - Parameters:
  ///   - newElements: The new elements to insert into the deque.
  ///   - index: The position at which to insert the new elements. `index` must
  ///      be a valid index of the deque (including `endIndex`).
  ///
  /// - Complexity: O(`count + newElements.count`). The operation shifts
  ///    existing elements either towards the beginning or the end of the deque
  ///    to minimize the number of elements that need to be moved. When
  ///    inserting at the start or the end, this reduces the complexity to
  ///    amortized O(1).
  /* was @inlinable */
  @usableFromInline internal /*was public */ mutating func insert<C: Collection>(
    contentsOf newElements: __owned C, at index: Index
  ) where C.Element == Element {
    precondition(index >= 0 && index <= count,
                 "Can't insert elements at an invalid index")
    let newCount = newElements.count
    _storage.ensureUnique(minimumCapacity: count + newCount)
    _storage.update { target in
      target.uncheckedInsert(contentsOf: newElements, count: newCount, atOffset: index)
    }
  }

  /// Removes and returns the element at the specified position.
  ///
  /// To close the resulting gap, all elements following the specified position
  /// are (logically) moved up by one index position. (Internally, the deque may
  /// actually decide to shift previous elements forward instead to minimize the
  /// number of elements that need to be moved.)
  ///
  /// - Parameters:
  ///   - index: The position of the element to remove. `index` must be a valid
  ///      index of the array.
  ///
  /// - Returns: The element originally at the specified index.
  ///
  /// - Complexity: O(`count`). Removing elements from the start or end of the
  ///    deque costs O(1) if the deque's storage isn't shared.
  /* was @inlinable */
  @discardableResult
  @usableFromInline internal /*was public */ mutating func remove(at index: Index) -> Element {
    precondition(index >= 0 && index < self.count, "Index out of bounds")
    // FIXME: Implement storage shrinking
    _storage.ensureUnique()
    return _storage.update { target in
      // FIXME: Add direct implementation & see if it makes a difference
      let result = self[index]
      target.uncheckedRemove(offsets: index ..< index + 1)
      return result
    }
  }

  /// Removes the elements in the specified subrange from the deque.

  /// All elements following the specified range are (logically) moved up to
  /// close the resulting gap. (Internally, the deque may actually decide to
  /// shift previous elements forward instead to minimize the number of elements
  /// that need to be moved.)
  ///
  /// - Parameters:
  ///   - bounds: The range of the collection to be removed. The bounds of the
  ///      range must be valid indices of the collection.
  ///
  /// - Complexity: O(`count`). Removing elements from the start or end of the
  ///    deque costs O(`bounds.count`) if the deque's storage isn't shared.
  /* was @inlinable */
  @usableFromInline internal /*was public */ mutating func removeSubrange(_ bounds: Range<Index>) {
    precondition(bounds.lowerBound >= 0 && bounds.upperBound <= self.count,
                 "Index range out of bounds")
    _storage.ensureUnique()
    _storage.update { $0.uncheckedRemove(offsets: bounds) }
  }

  /* was @inlinable */
  @usableFromInline internal /*was public */ mutating func _customRemoveLast() -> Element? {
    precondition(!isEmpty, "Cannot remove last element of an empty NIODeque")
    _storage.ensureUnique()
    return _storage.update { $0.uncheckedRemoveLast() }
  }

  /* was @inlinable */
  @usableFromInline internal /*was public */ mutating func _customRemoveLast(_ n: Int) -> Bool {
    precondition(n >= 0, "Can't remove a negative number of elements")
    precondition(n <= count, "Can't remove more elements than there are in the Collection")
    _storage.ensureUnique()
    _storage.update { $0.uncheckedRemoveLast(n) }
    return true
  }

  /// Removes and returns the first element of the deque.
  ///
  /// The collection must not be empty.
  ///
  /// - Returns: The removed element.
  ///
  /// - Complexity: O(1) if the underlying storage isn't shared; otherwise
  ///    O(`count`).
  /* was @inlinable */
  @discardableResult
  @usableFromInline internal /*was public */ mutating func removeFirst() -> Element {
    precondition(!isEmpty, "Cannot remove first element of an empty NIODeque")
    _storage.ensureUnique()
    return _storage.update { $0.uncheckedRemoveFirst() }
  }

  /// Removes the specified number of elements from the beginning of the deque.
  ///
  /// - Parameter n: The number of elements to remove from the deque. `n` must
  ///    be greater than or equal to zero and must not exceed the number of
  ///    elements in the deque.
  ///
  /// - Complexity: O(`n`) if the underlying storage isn't shared; otherwise
  ///    O(`count`).
  /* was @inlinable */
  @usableFromInline internal /*was public */ mutating func removeFirst(_ n: Int) {
    precondition(n >= 0, "Can't remove a negative number of elements")
    precondition(n <= count, "Can't remove more elements than there are in the Collection")
    _storage.ensureUnique()
    return _storage.update { $0.uncheckedRemoveFirst(n) }
  }

  /// Removes all elements from the deque.
  ///
  /// - Parameter keepCapacity: Pass true to keep the existing storage capacity
  ///    of the deque after removing its elements. The default value is false.
  ///
  /// - Complexity: O(`count`)
  /* was @inlinable */
  @usableFromInline internal /*was public */ mutating func removeAll(keepingCapacity keepCapacity: Bool = false) {
    if keepCapacity {
      _storage.ensureUnique()
      _storage.update { $0.uncheckedRemoveAll() }
    } else {
      self = NIODeque()
    }
  }
}
