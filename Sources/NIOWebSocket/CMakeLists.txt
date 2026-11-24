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

add_library(NIOWebSocket
  "NIOWebSocketClientUpgrader.swift"
  "NIOWebSocketFrameAggregator.swift"
  "NIOWebSocketServerUpgrader.swift"
  "SHA1.swift"
  "WebSocketErrorCodes.swift"
  "WebSocketFrame.swift"
  "WebSocketFrameDecoder.swift"
  "WebSocketFrameEncoder.swift"
  "WebSocketOpcode.swift"
  "WebSocketProtocolErrorHandler.swift"
)

target_link_libraries(NIOWebSocket PUBLIC
  $<$<PLATFORM_ID:Darwin,iOS,tvOS,watchOS,Linux,Android>:NIO>
  NIOCore
  NIOHTTP1
  CNIOSHA1
  _NIOBase64)

target_compile_options(NIOWebSocket PRIVATE ${SWIFT_NIO_COMPILE_OPTIONS})
target_compile_definitions(NIOWebSocket PRIVATE $<$<NOT:$<CONFIG:Release,RelWithDebInfo,MinSizeRel>>:DEBUG>)
set_target_properties(NIOWebSocket PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

swift_nio_install_target(NIOWebSocket)
set_property(GLOBAL APPEND PROPERTY SWIFT_NIO_EXPORTS NIOWebSocket)
