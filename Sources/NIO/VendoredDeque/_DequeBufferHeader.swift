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
internal struct _NIODequeBufferHeader {
  @usableFromInline
  var capacity: Int

  @usableFromInline
  var count: Int

  @usableFromInline
  var startSlot: _NIODequeSlot

  @usableFromInline
  init(capacity: Int, count: Int, startSlot: _NIODequeSlot) {
    self.capacity = capacity
    self.count = count
    self.startSlot = startSlot
    _checkInvariants()
  }

  #if COLLECTIONS_INTERNAL_CHECKS
  @usableFromInline @inline(never) @_effects(releasenone)
  internal func _checkInvariants() {
    precondition(capacity >= 0)
    precondition(count >= 0 && count <= capacity)
    precondition(startSlot.position >= 0 && startSlot.position <= capacity)
  }
  #else
  /* was @inlinable */ @inline(__always)
  internal func _checkInvariants() {}
  #endif // COLLECTIONS_INTERNAL_CHECKS
}

extension _NIODequeBufferHeader: CustomStringConvertible {
  @usableFromInline
  internal var description: String {
    "(capacity: \(capacity), count: \(count), startSlot: \(startSlot))"
  }
}
