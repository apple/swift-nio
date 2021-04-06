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

extension Collection {
  /* was @inlinable */
  @inline(__always)
  internal func _rebased<Element>() -> UnsafeBufferPointer<Element>
  where Self == UnsafeBufferPointer<Element>.SubSequence {
    .init(rebasing: self)
  }
}

extension Collection {
  /* was @inlinable */
  @inline(__always)
  internal func _rebased<Element>() -> UnsafeMutableBufferPointer<Element>
  where Self == UnsafeMutableBufferPointer<Element>.SubSequence {
    .init(rebasing: self)
  }
}

extension UnsafeMutableBufferPointer {
  /* was @inlinable */
  @inline(__always)
  internal func _initialize(from source: UnsafeBufferPointer<Element>) {
    assert(source.count == count)
    guard source.count > 0 else { return }
    baseAddress!.initialize(from: source.baseAddress!, count: source.count)
  }

  /* was @inlinable */
  @inline(__always)
  internal func _initialize<C: Collection>(
    from elements: C
  ) where C.Element == Element {
    assert(elements.count == count)
    var (it, copied) = elements._copyContents(initializing: self)
    precondition(copied == count)
    precondition(it.next() == nil)
  }

  /* was @inlinable */
  @inline(__always)
  internal func _deinitializeAll() {
    guard count > 0 else { return }
    baseAddress!.deinitialize(count: count)
  }

  /* was @inlinable */
  internal func _assign<C: Collection>(
    from replacement: C
  ) where C.Element == Element {
    guard self.count > 0 else { return }
    self[0 ..< count]._rebased()._deinitializeAll()
    _initialize(from: replacement)
  }
}
