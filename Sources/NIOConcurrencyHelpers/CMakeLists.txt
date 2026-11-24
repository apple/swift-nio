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

add_library(NIOConcurrencyHelpers
  "NIOAtomic.swift"
  "NIOLock.swift"
  "NIOLockedValueBox.swift"
  "NIOThreadPoolWorkAvailable.swift"
  "atomics.swift"
  "lock.swift"
)

target_link_libraries(NIOConcurrencyHelpers PUBLIC
  CNIOAtomics)

target_compile_options(NIOConcurrencyHelpers PRIVATE ${SWIFT_NIO_COMPILE_OPTIONS})
target_compile_definitions(NIOConcurrencyHelpers PRIVATE $<$<NOT:$<CONFIG:Release,RelWithDebInfo,MinSizeRel>>:DEBUG>)
set_target_properties(NIOConcurrencyHelpers PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

swift_nio_install_target(NIOConcurrencyHelpers)
set_property(GLOBAL APPEND PROPERTY SWIFT_NIO_EXPORTS NIOConcurrencyHelpers)
