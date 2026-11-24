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

add_library(CNIOWindows STATIC
  "WSAStartup.c"
  "shim.c"
)

target_include_directories(CNIOWindows PUBLIC
  include)

# `WSAStartup.c` calls into Winsock.
target_link_libraries(CNIOWindows PUBLIC
  $<$<PLATFORM_ID:Windows>:ws2_32>)

# `WSAStartup.c` initialises Winsock from a `.CRT$XCU` initializer that nothing references, so
# make sure the linker keeps it.
target_link_options(CNIOWindows INTERFACE
  $<$<PLATFORM_ID:Windows>:LINKER:/INCLUDE:NIOWSAStartup_ptr>)

set_target_properties(CNIOWindows PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_CURRENT_SOURCE_DIR}/include;${CMAKE_Swift_MODULE_DIRECTORY}")

set_property(GLOBAL APPEND PROPERTY SWIFT_NIO_EXPORTS CNIOWindows)
