add_library(NIOTestUtils
  ByteToMessageDecoderVerifier.swift
  EventCounterHandler.swift
  NIOHTTP1TestServer.swift)
target_link_libraries(NIOTestUtils PUBLIC
  CNIOHTTPParser
  NIO
  NIOHTTP1)
set_target_properties(NIOTestUtils PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})
