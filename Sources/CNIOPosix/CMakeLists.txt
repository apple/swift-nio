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

add_library(CNIOPosix STATIC
  "event_loop_id.c"
)

target_include_directories(CNIOPosix PUBLIC
  include)

target_compile_definitions(CNIOPosix PRIVATE
  _GNU_SOURCE)

set_target_properties(CNIOPosix PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_CURRENT_SOURCE_DIR}/include;${CMAKE_Swift_MODULE_DIRECTORY}")

set_property(GLOBAL APPEND PROPERTY SWIFT_NIO_EXPORTS CNIOPosix)
