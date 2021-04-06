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

@usableFromInline
/* was @frozen */
internal struct _NIODequeSlot {
  @usableFromInline
  internal var position: Int

  /* was @inlinable */
  @inline(__always)
  init(at position: Int) {
    assert(position >= 0)
    self.position = position
  }
}

extension _NIODequeSlot {
  /* was @inlinable */
  @inline(__always)
  internal static var zero: Self { Self(at: 0) }

  /* was @inlinable */
  @inline(__always)
  internal func advanced(by delta: Int) -> Self {
    Self(at: position &+ delta)
  }

  /* was @inlinable */
  @inline(__always)
  internal func orIfZero(_ value: Int) -> Self {
    guard position > 0 else { return Self(at: value) }
    return self
  }
}

extension _NIODequeSlot: CustomStringConvertible {
  @usableFromInline
  internal var description: String {
    "@\(position)"
  }
}

extension _NIODequeSlot: Equatable {
  /* was @inlinable */
  @inline(__always)
  @usableFromInline static func ==(left: Self, right: Self) -> Bool {
    left.position == right.position
  }
}

extension _NIODequeSlot: Comparable {
  /* was @inlinable */
  @inline(__always)
  @usableFromInline static func <(left: Self, right: Self) -> Bool {
    left.position < right.position
  }
}

extension Range where Bound == _NIODequeSlot {
  /* was @inlinable */
  @inline(__always)
  internal var _count: Int { upperBound.position - lowerBound.position }
}
