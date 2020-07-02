add_library(NIOFoundationCompatTests SHARED
  ByteBufferView+MutableDataProtocol.swift
  Codable+ByteBufferTest+XCTest.swift
  Codable+ByteBufferTest.swift)
target_compile_options(NIOFoundationCompatTests PRIVATE
  -enable-testing)
target_link_libraries(NIOFoundationCompatTests PUBLIC
  Foundation
  NIO
  NIOFoundationCompat
  XCTest)
