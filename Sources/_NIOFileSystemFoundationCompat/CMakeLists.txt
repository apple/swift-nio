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

add_library(_NIOFileSystemFoundationCompat
  "Data+FileSystem.swift"
  "Date+FileInfo.swift"
)

target_link_libraries(_NIOFileSystemFoundationCompat PUBLIC
  _NIOFileSystem
  NIOCore
  NIOFoundationEssentialsCompat
  $<$<NOT:$<PLATFORM_ID:Darwin>>:$<TARGET_NAME_IF_EXISTS:FoundationEssentials>>)

target_compile_options(_NIOFileSystemFoundationCompat PRIVATE ${SWIFT_NIO_COMPILE_OPTIONS})
target_compile_definitions(_NIOFileSystemFoundationCompat PRIVATE $<$<NOT:$<CONFIG:Release,RelWithDebInfo,MinSizeRel>>:DEBUG>)
set_target_properties(_NIOFileSystemFoundationCompat PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

swift_nio_install_target(_NIOFileSystemFoundationCompat)
set_property(GLOBAL APPEND PROPERTY SWIFT_NIO_EXPORTS _NIOFileSystemFoundationCompat)
