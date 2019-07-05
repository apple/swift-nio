add_library(NIOTestUtils
  ByteToMessageDecoderVerifier.swift
)
target_link_libraries(NIOTestUtils PUBLIC NIO)
target_include_directories(NIOTestUtils INTERFACE $<TARGET_PROPERTY:NIOTestUtils,Swift_MODULE_DIRECTORY>)
