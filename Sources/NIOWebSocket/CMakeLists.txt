add_library(NIOWebSocket
  Base64.swift
  NIOWebSocketServerUpgrader.swift
  SHA1.swift
  WebSocketErrorCodes.swift
  WebSocketFrame.swift
  WebSocketFrameDecoder.swift
  WebSocketFrameEncoder.swift
  WebSocketOpcode.swift
  WebSocketProtocolErrorHandler.swift
)
target_link_libraries(NIOWebSocket NIO NIOHTTP1 CNIOSHA1)
target_include_directories(NIOWebSocket PUBLIC ${CMAKE_Swift_MODULE_DIRECTORY})
