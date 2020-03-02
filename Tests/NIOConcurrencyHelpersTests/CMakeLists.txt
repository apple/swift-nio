add_library(NIOConcurrencyHelpersTests SHARED
  NIOConcurrencyHelpersTests.swift
  NIOConcurrencyHelpersTests+XCTest.swift)
target_compile_options(NIOConcurrencyHelpersTests PRIVATE
  -enable-testing)
target_link_libraries(NIOConcurrencyHelpersTests PUBLIC
  swiftDispatch
  NIO
  XCTest)
