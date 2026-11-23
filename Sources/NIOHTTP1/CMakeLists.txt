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

add_library(NIOHTTP1
  "ByteCollectionUtils.swift"
  "HTTPDecoder.swift"
  "HTTPEncoder.swift"
  "HTTPHeaderValidator.swift"
  "HTTPHeaders+Validation.swift"
  "HTTPPipelineSetup.swift"
  "HTTPServerPipelineHandler.swift"
  "HTTPServerProtocolErrorHandler.swift"
  "HTTPServerRequestMethodQueue.swift"
  "HTTPServerUpgradeHandler.swift"
  "HTTPTypedPipelineSetup.swift"
  "HTTPTypes.swift"
  "NIOHTTPClientUpgradeHandler.swift"
  "NIOHTTPObjectAggregator.swift"
  "NIOTypedHTTPClientUpgradeHandler.swift"
  "NIOTypedHTTPClientUpgraderStateMachine.swift"
  "NIOTypedHTTPServerUpgradeHandler.swift"
  "NIOTypedHTTPServerUpgraderStateMachine.swift"
)

# CNIOLLHTTP is only imported with `private import`, so it is linked privately. NIOHTTP1 is not built with
# library evolution though, so its module file still requires CNIOLLHTTP's module to be loadable by clients:
# forward the headers and module map (but not the archive) to them. Static builds still link the archive via
# LINK_ONLY.
target_link_libraries(NIOHTTP1
  PUBLIC
    $<$<PLATFORM_ID:Darwin,iOS,tvOS,watchOS,Linux,Android>:NIO>
    NIOCore
    NIOConcurrencyHelpers
    SwiftCollections::DequeModule
  PRIVATE
    CNIOLLHTTP
  INTERFACE
    $<COMPILE_ONLY:CNIOLLHTTP>)

target_compile_options(NIOHTTP1 PRIVATE ${SWIFT_NIO_COMPILE_OPTIONS})
target_compile_definitions(NIOHTTP1 PRIVATE $<$<NOT:$<CONFIG:Release,RelWithDebInfo,MinSizeRel>>:DEBUG>)
set_target_properties(NIOHTTP1 PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

swift_nio_install_target(NIOHTTP1)
set_property(GLOBAL APPEND PROPERTY SWIFT_NIO_EXPORTS NIOHTTP1)
