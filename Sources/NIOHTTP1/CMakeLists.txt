add_library(NIOHTTP1
  ByteCollectionUtils.swift
  HTTPDecoder.swift
  HTTPEncoder.swift
  HTTPPipelineSetup.swift
  HTTPServerPipelineHandler.swift
  HTTPServerProtocolErrorHandler.swift
  HTTPServerUpgradeHandler.swift
  HTTPTypes.swift
)
target_link_libraries(NIOHTTP1 PUBLIC CNIOHTTPParser NIO NIOConcurrencyHelpers)
target_include_directories(NIOHTTP1 PUBLIC ${CMAKE_Swift_MODULE_DIRECTORY})
