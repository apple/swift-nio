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
internal class _NIODequeBuffer<Element>: ManagedBuffer<_NIODequeBufferHeader, Element> {
  /* was @inlinable */
  deinit {
    let storage = NIODeque<Element>._Storage(self)
    storage.update { handle in
    }
    self.withUnsafeMutablePointers { header, elements in
      header.pointee._checkInvariants()

      let capacity = header.pointee.capacity
      let count = header.pointee.count
      let startSlot = header.pointee.startSlot

      if startSlot.position + count <= capacity {
        (elements + startSlot.position).deinitialize(count: count)
      } else {
        let firstRegion = capacity - startSlot.position
        (elements + startSlot.position).deinitialize(count: firstRegion)
        elements.deinitialize(count: count - firstRegion)
      }
    }
  }
}

extension _NIODequeBuffer: CustomStringConvertible {
  @usableFromInline
  internal var description: String {
    withUnsafeMutablePointerToHeader { "_NIODequeStorage<\(Element.self)>\($0.pointee)" }
  }
}

/// The type-punned empty singleton storage instance.
@usableFromInline
internal let _emptyNIODequeStorage = _NIODequeBuffer<Void>.create(
  minimumCapacity: 0,
  makingHeaderWith: { _ in
    _NIODequeBufferHeader(capacity: 0, count: 0, startSlot: .init(at: 0))
  })

