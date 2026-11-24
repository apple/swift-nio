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

add_library(NIOFSFoundationCompat
  "Data+FileSystem.swift"
  "Date+FileInfo.swift"
)

target_link_libraries(NIOFSFoundationCompat PUBLIC
  NIOFS
  NIOCore
  NIOFoundationEssentialsCompat
  $<$<NOT:$<PLATFORM_ID:Darwin>>:$<TARGET_NAME_IF_EXISTS:FoundationEssentials>>)

target_compile_options(NIOFSFoundationCompat PRIVATE ${SWIFT_NIO_COMPILE_OPTIONS})
target_compile_definitions(NIOFSFoundationCompat PRIVATE $<$<NOT:$<CONFIG:Release,RelWithDebInfo,MinSizeRel>>:DEBUG>)
set_target_properties(NIOFSFoundationCompat PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

swift_nio_install_target(NIOFSFoundationCompat)
set_property(GLOBAL APPEND PROPERTY SWIFT_NIO_EXPORTS NIOFSFoundationCompat)
