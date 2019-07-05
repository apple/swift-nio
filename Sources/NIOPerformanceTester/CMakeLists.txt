add_executable(NIOPerformanceTester
  main.swift
  resources.swift
)
target_link_libraries(NIOPerformanceTester NIO NIOFoundationCompat NIOHTTP1)
