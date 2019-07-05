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
  add_compile_options("$<$<COMPILE_LANGUAGE:Swift>:-target;x86_64-apple-macosx10.14>")
  # XXX: Workaround "Cannot load underlying module for Darwin"
  add_compile_options("$<$<COMPILE_LANGUAGE:Swift>:-sdk;${CMAKE_OSX_SYSROOT}>")
endif()

# XXX: -O -gline-tables-only gets passed to executables but not to shared libraries
add_compile_options(
  "$<$<AND:$<CONFIG:Debug>,$<COMPILE_LANGUAGE:Swift>>:-g;-Onone;-assert-config;Debug>"
  "$<$<AND:$<CONFIG:RelWithDebugInfo>,$<COMPILE_LANGUAGE:Swift>>:-O;-gline-tables-only;-assert-config;Release>"
  "$<$<AND:$<CONFIG:Release>,$<COMPILE_LANGUAGE:Swift>>:-O;-assert-config;Release>"
)

# Helper Libraries
set(NIO_C_LIBRARIES
  CNIOAtomics
  CNIODarwin
  CNIOHTTPParser
  CNIOLinux
  CNIOSHA1
)
set(NIO_Swift_LIBRARIES
  NIO
  NIOConcurrencyHelpers
  NIOFoundationCompat
  NIOHTTP1
  NIOTLS
  NIOTestUtils
  NIOWebSocket
)
set(NIO_DEMO_PROGRAMS
  NIOChatClient
  NIOChatServer
  NIOEchoClient
  NIOEchoServer
  NIOHTTP1Client
  NIOHTTP1Server
  NIOMulticastChat
  NIOPerformanceTester
  NIOWebSocketServer
)

foreach(subdir IN LISTS NIO_C_LIBRARIES NIO_Swift_LIBRARIES NIO_DEMO_PROGRAMS)
  add_subdirectory(Sources/${subdir})
endforeach()

### MARK - Hacks

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
    target_link_options(${nio_library} INTERFACE $<BUILD_INTERFACE:LINKER:-rpath,$<TARGET_LINKER_FILE_DIR:${nio_library}>>)

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

# Sanity Check
file(GLOB NIO_MODULES "${CMAKE_CURRENT_LIST_DIR}/Sources/*")
foreach(nio_module IN LISTS NIO_MODULES)
  get_filename_component(nio_module "${nio_module}" NAME)
  if(NOT TARGET ${nio_module})
    message(WARNING "No CMake target for NIO module ${nio_module}")
  endif()
endforeach()

