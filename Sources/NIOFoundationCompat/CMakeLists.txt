add_library(NIOFoundationCompat
  ByteBuffer-foundation.swift
)
target_link_libraries(NIOFoundationCompat PUBLIC NIO)
target_include_directories(NIOFoundationCompat PUBLIC $<BUILD_INTERFACE:$<TARGET_PROPERTY:NIOFoundationCompat,Swift_MODULE_DIRECTORY>>)
