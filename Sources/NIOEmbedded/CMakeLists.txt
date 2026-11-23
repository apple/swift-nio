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

add_library(NIOEmbedded
  "AsyncTestingChannel.swift"
  "AsyncTestingEventLoop.swift"
  "Embedded.swift"
)

target_link_libraries(NIOEmbedded PUBLIC
  $<$<NOT:$<PLATFORM_ID:Darwin>>:dispatch>
  NIOCore
  NIOConcurrencyHelpers
  _NIODataStructures
  SwiftAtomics::Atomics
  SwiftCollections::DequeModule)

target_compile_options(NIOEmbedded PRIVATE ${SWIFT_NIO_COMPILE_OPTIONS})
target_compile_definitions(NIOEmbedded PRIVATE $<$<NOT:$<CONFIG:Release,RelWithDebInfo,MinSizeRel>>:DEBUG>)
set_target_properties(NIOEmbedded PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

swift_nio_install_target(NIOEmbedded)
set_property(GLOBAL APPEND PROPERTY SWIFT_NIO_EXPORTS NIOEmbedded)
