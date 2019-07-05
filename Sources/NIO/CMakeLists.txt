file(GLOB_RECURSE NIO_SWIFT_SOURCES CONFIGURE_DEPENDS "*.swift")
add_library(NIO ${NIO_SWIFT_SOURCES})
target_link_libraries(NIO PUBLIC CNIOAtomics NIOConcurrencyHelpers CNIOLinux CNIODarwin)
target_include_directories(NIO INTERFACE $<BUILD_INTERFACE:$<TARGET_PROPERTY:NIO,Swift_MODULE_DIRECTORY>>)
