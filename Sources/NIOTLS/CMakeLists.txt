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

add_library(NIOTLS
  "ApplicationProtocolNegotiationHandler.swift"
  "NIOTypedApplicationProtocolNegotiationHandler.swift"
  "ProtocolNegotiationHandlerStateMachine.swift"
  "SNIHandler.swift"
  "TLSEvents.swift"
)

target_link_libraries(NIOTLS PUBLIC
  $<$<PLATFORM_ID:Darwin,iOS,tvOS,watchOS,Linux,Android>:NIO>
  NIOCore
  SwiftCollections::DequeModule)

target_compile_options(NIOTLS PRIVATE ${SWIFT_NIO_COMPILE_OPTIONS})
target_compile_definitions(NIOTLS PRIVATE $<$<NOT:$<CONFIG:Release,RelWithDebInfo,MinSizeRel>>:DEBUG>)
set_target_properties(NIOTLS PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

swift_nio_install_target(NIOTLS)
set_property(GLOBAL APPEND PROPERTY SWIFT_NIO_EXPORTS NIOTLS)
