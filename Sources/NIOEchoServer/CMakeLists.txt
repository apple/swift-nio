add_executable(NIOEchoServer
  main.swift)
target_link_libraries(NIOEchoServer PRIVATE
  NIO)
