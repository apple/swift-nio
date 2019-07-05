# Support for building and installing the NIO programs with CMake
cmake_minimum_required(VERSION 3.14.20190603)

project(swift-nio-demos LANGUAGES C Swift VERSION 2.3.0)

include(GNUInstallDirs)

set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
set(CMAKE_Swift_MODULE_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/swiftmodules)

if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
  set(CMAKE_Swift_FLAGS "${CMAKE_Swift_FLAGS} -target x86_64-apple-macosx10.14")
  # XXX: Workaround "Cannot load underlying module for Darwin"
  set(CMAKE_Swift_FLAGS "${CMAKE_Swift_FLAGS} -sdk ${CMAKE_OSX_SYSROOT}")
endif()

add_subdirectory(Sources/CNIOAtomics)

add_subdirectory(Sources/NIOConcurrencyHelpers)

add_subdirectory(Sources/CNIOSHA1)

add_subdirectory(Sources/CNIOLinux)

add_subdirectory(Sources/CNIODarwin)

add_subdirectory(Sources/NIO)

add_subdirectory(Sources/CNIOHTTPParser)
add_subdirectory(Sources/NIOHTTP1)

add_subdirectory(Sources/NIOWebSocket)

add_subdirectory(Sources/NIOChatClient)
add_subdirectory(Sources/NIOChatServer)
add_subdirectory(Sources/NIOEchoClient)
add_subdirectory(Sources/NIOEchoServer)

add_subdirectory(Sources/NIOHTTP1Server)
add_subdirectory(Sources/NIOHTTP1Client)

#        .executable(name: "NIOWebSocketServer",
#                    targets: ["NIOWebSocketServer"]),
#        .executable(name: "NIOPerformanceTester",
#                    targets: ["NIOPerformanceTester"]),
#        .executable(name: "NIOMulticastChat", targets: ["NIOMulticastChat"]),
#        .executable(name: "NIOUDPEchoServer", targets: ["NIOUDPEchoServer"]),
#        .executable(name: "NIOUDPEchoClient", targets: ["NIOUDPEchoClient"]),

set(NIO_C_LIBRARIES CNIOAtomics CNIOSHA1 CNIOLinux CNIODarwin CNIOHTTPParser)
set(NIO_Swift_LIBRARIES NIOConcurrencyHelpers NIO NIOHTTP1 NIOWebSocket)
set(NIO_DEMO_PROGRAMS NIOChatClient NIOChatServer NIOEchoClient NIOEchoServer NIOHTTP1Server NIOHTTP1Client)

if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
  # XXX: CMake doesn't set LC_ID on Swift SHARED libraries, so we need to fix install_name here
  foreach(nio_library IN LISTS NIO_Swift_LIBRARIES)
    set_property(TARGET ${nio_library} APPEND PROPERTY LINK_FLAGS "-Xlinker -install_name -Xlinker @rpath/lib${nio_library}.dylib")
  endforeach()
  foreach(nio_demo_program IN LISTS NIO_DEMO_PROGRAMS)
    set_property(TARGET ${nio_demo_program} APPEND PROPERTY
      LINK_FLAGS "-Xlinker -rpath -Xlinker @executable_path/../lib"
    )
  endforeach()
  set(CMAKE_INSTALL_RPATH "@executable_path/../lib")
endif()

install(TARGETS ${NIO_LIBRARIES} ${NIO_DEMO_PROGRAMS}
  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}/NIO
)

include(CPack)
