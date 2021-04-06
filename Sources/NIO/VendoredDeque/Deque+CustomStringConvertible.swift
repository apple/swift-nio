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

extension NIODeque: CustomStringConvertible {
  /// A textual representation of this instance.
  @usableFromInline internal /*was public */ var description: String {
    var result = "["
    var first = true
    for item in self {
      if first {
        first = false
      } else {
        result += ", "
      }
      print(item, terminator: "", to: &result)
    }
    result += "]"
    return result
  }
}
