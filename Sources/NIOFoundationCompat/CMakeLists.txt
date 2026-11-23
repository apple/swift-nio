##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

add_library(NIOFoundationCompat
  "Exports.swift"
  "JSONSerialization+ByteBuffer.swift"
  "WaitSpinningRunLoop.swift"
)

target_link_libraries(NIOFoundationCompat PUBLIC
  $<$<PLATFORM_ID:Darwin,iOS,tvOS,watchOS,Linux,Android>:NIO>
  NIOCore
  NIOFoundationEssentialsCompat
  NIOConcurrencyHelpers
  SwiftAtomics::Atomics
  $<$<NOT:$<PLATFORM_ID:Darwin>>:Foundation>)

target_compile_options(NIOFoundationCompat PRIVATE ${SWIFT_NIO_COMPILE_OPTIONS})
target_compile_definitions(NIOFoundationCompat PRIVATE $<$<NOT:$<CONFIG:Release,RelWithDebInfo,MinSizeRel>>:DEBUG>)
set_target_properties(NIOFoundationCompat PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

swift_nio_install_target(NIOFoundationCompat)
set_property(GLOBAL APPEND PROPERTY SWIFT_NIO_EXPORTS NIOFoundationCompat)
