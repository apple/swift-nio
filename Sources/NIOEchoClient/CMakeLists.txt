add_executable(NIOEchoClient
  main.swift)
target_link_libraries(NIOEchoClient PRIVATE
  NIO)
