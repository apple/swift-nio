add_executable(NIOPerformanceTester
  Benchmark.swift
  ChannelPipelineBenchmark.swift
  main.swift
  resources.swift
)
target_link_libraries(NIOPerformanceTester NIO NIOFoundationCompat NIOHTTP1)
