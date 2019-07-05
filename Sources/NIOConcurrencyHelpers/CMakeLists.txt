add_library(NIOConcurrencyHelpers
  atomics.swift
  lock.swift
)
target_link_libraries(NIOConcurrencyHelpers PUBLIC CNIOAtomics)
target_include_directories(NIOConcurrencyHelpers PUBLIC $<TARGET_PROPERTY:NIOConcurrencyHelpers,Swift_MODULE_DIRECTORY>)
