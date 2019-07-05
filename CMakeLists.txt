# Support for building and installing the NIO demo programs with CMake
#
# To build with CMake use
#     mkdir build
#     cd build
#     cmake -GNinja -DCMAKE_BUILD_TYPE=RelWithDebugInfo -DBUILD_SHARED_LIBS:ON ..
#     ninja
#     ninja package
cmake_minimum_required(VERSION 3.14.20190603)

project(swift-nio-demos LANGUAGES C Swift VERSION 2.3.0)

include(GNUInstallDirs)

set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
set(CMAKE_Swift_MODULE_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/swiftmodules)
list(APPEND CMAKE_BUILD_RPATH "${CMAKE_LIBRARY_OUTPUT_DIRECTORY}")

add_compile_options($<$<COMPILE_LANGUAGE:Swift>:-warnings-as-errors>)

if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
  set(CMAKE_Swift_FLAGS "${CMAKE_Swift_FLAGS} -target x86_64-apple-macosx10.14")
  # XXX: Workaround "Cannot load underlying module for Darwin"
  set(CMAKE_Swift_FLAGS "${CMAKE_Swift_FLAGS} -sdk ${CMAKE_OSX_SYSROOT}")
endif()

# Helper Libraries

add_subdirectory(Sources/CNIOAtomics)
add_subdirectory(Sources/NIOConcurrencyHelpers)
add_subdirectory(Sources/CNIOSHA1)
add_subdirectory(Sources/CNIOLinux)
add_subdirectory(Sources/CNIODarwin)
add_subdirectory(Sources/CNIOHTTPParser)

# Libraries
add_subdirectory(Sources/NIO)
add_subdirectory(Sources/NIOHTTP1)
add_subdirectory(Sources/NIOWebSocket)
add_subdirectory(Sources/NIOFoundationCompat)

# Demo Programs
add_subdirectory(Sources/NIOChatClient)
add_subdirectory(Sources/NIOChatServer)
add_subdirectory(Sources/NIOEchoClient)
add_subdirectory(Sources/NIOEchoServer)
add_subdirectory(Sources/NIOHTTP1Server)
add_subdirectory(Sources/NIOHTTP1Client)
add_subdirectory(Sources/NIOWebSocketServer)
add_subdirectory(Sources/NIOPerformanceTester)

#        .executable(name: "NIOWebSocketServer",
#                    targets: ["NIOWebSocketServer"]),
#        .executable(name: "NIOPerformanceTester",
#                    targets: ["NIOPerformanceTester"]),
#        .executable(name: "NIOMulticastChat", targets: ["NIOMulticastChat"]),
#        .executable(name: "NIOUDPEchoServer", targets: ["NIOUDPEchoServer"]),
#        .executable(name: "NIOUDPEchoClient", targets: ["NIOUDPEchoClient"]),

set(NIO_C_LIBRARIES CNIOAtomics CNIOSHA1 CNIOLinux CNIODarwin CNIOHTTPParser)
set(NIO_Swift_LIBRARIES NIOConcurrencyHelpers NIO NIOHTTP1 NIOWebSocket)
set(NIO_DEMO_PROGRAMS NIOChatClient NIOChatServer NIOEchoClient NIOEchoServer NIOHTTP1Server NIOHTTP1Client NIOPerformanceTester NIOWebSocketServer)

set(CMAKE_LINK_WHAT_YOU_USE ON)

### MARK - Hacks

# XXX: -O -gline-tables-only gets passed to executables but not to shared libraries
foreach(nio_library IN LISTS NIO_Swift_LIBRARIES NIO_DEMO_PROGRAMS)
  target_compile_options(${nio_library} PRIVATE
      $<$<CONFIG:Debug>:-g;-Onone;-assert-config;Debug>
      $<$<CONFIG:RelWithDebugInfo>:-O;-gline-tables-only;-assert-config;Release>
      $<$<CONFIG:Release>:-O;-assert-config;Release>
  )
endforeach()

if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
  # XXX: CMake doesn't set LC_ID on Swift SHARED libraries, so we need to fix install_name here
  foreach(nio_library IN LISTS NIO_Swift_LIBRARIES)
    target_link_options(${nio_library} PRIVATE LINKER:-install_name,@rpath/$<TARGET_LINKER_FILE_NAME:${nio_library}>)
    target_link_options(${nio_library} INTERFACE LINKER:-rpath,$<TARGET_LINKER_FILE_DIR:${nio_library}>)
  endforeach()
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  foreach(nio_library IN LISTS NIO_Swift_LIBRARIES)
    # XXX: CMake doesn't set SONAME on Swift SHARED libraries, so we need to fix it here
    target_link_options(${nio_library} PRIVATE LINKER:-soname,$<TARGET_LINKER_FILE_NAME:${nio_library}>)
    target_link_options(${nio_library} INTERFACE LINKER:-rpath,$<TARGET_LINKER_FILE_DIR:${nio_library}>)

    # XXX: swift-autolink-extract always prefers the -l mode
    # so we need to expect -lNIOConcurrencyHelpers on the command-line
    target_link_options(${nio_library} INTERFACE -L$<TARGET_LINKER_FILE_DIR:${nio_library}>)
  endforeach()
endif()

### MARK - Packaging

install(TARGETS ${NIO_LIBRARIES} ${NIO_DEMO_PROGRAMS}
  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}/NIO
)

include(CPack)
