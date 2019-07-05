add_library(NIOConcurrencyHelpers
  atomics.swift
  lock.swift
)
target_link_libraries(NIOConcurrencyHelpers PUBLIC CNIOAtomics)
target_include_directories(NIOConcurrencyHelpers PUBLIC ${CMAKE_Swift_MODULE_DIRECTORY})
