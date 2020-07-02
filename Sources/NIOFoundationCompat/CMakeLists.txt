add_library(NIOFoundationCompat
  ByteBuffer-Foundation.swift
  Codable+ByteBuffer.swift)
target_link_libraries(NIOFoundationCompat PUBLIC
  NIO)
set_target_properties(NIOFoundationCompat PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})
