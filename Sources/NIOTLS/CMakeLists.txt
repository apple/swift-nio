add_library(NIOTLS
  ApplicationProtocolNegotiationHandler.swift
  SNIHandler.swift
  TLSEvents.swift
)
target_link_libraries(NIOTLS NIO)
target_include_directories(NIOTLS INTERFACE $<TARGET_PROPERTY:NIOTLS,Swift_MODULE_DIRECTORY>)
