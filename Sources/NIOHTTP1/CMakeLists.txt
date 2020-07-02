add_library(NIOHTTP1
  ByteCollectionUtils.swift
  HTTPDecoder.swift
  HTTPEncoder.swift
  HTTPPipelineSetup.swift
  HTTPServerPipelineHandler.swift
  HTTPServerProtocolErrorHandler.swift
  HTTPServerUpgradeHandler.swift
  HTTPTypes.swift
  NIOHTTPClientUpgradeHandler.swift)
target_compile_options(NIOHTTP1 PRIVATE
  $<$<BOOL:${BUILD_TESTING}>:-enable-testing>)
target_link_libraries(NIOHTTP1 PRIVATE
  CNIOHTTPParser)
target_link_libraries(NIOHTTP1 PUBLIC
  NIO)
set_target_properties(NIOHTTP1 PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})
