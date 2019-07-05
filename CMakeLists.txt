# Support for building and installing the NIO demo programs with CMake
#
# CMake 3.15.0-rc3 is required for Swift support.
# Ninja is also required.
#
# To build with CMake on Darwin
#     mkdir build-darwin
#     cd build-darwin
#     cmake -GNinja -DCMAKE_BUILD_TYPE=RelWithDebugInfo -DBUILD_SHARED_LIBS:ON ..
#     ninja
#     # Create an installable package
#     cpack -G TGZ .
#     # Run integration tests
#     ctest -VV .
# To build with CMake on Linux
#     docker-compose -f docker/docker-compose.yaml -f docker/docker-compose.1804.50.yaml up --build cmake-integration-tests
cmake_minimum_required(VERSION 3.14.20190603)

project(SwiftNIODemo LANGUAGES C Swift VERSION 2.3.0)

include(GNUInstallDirs)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib/SwiftNIODemo)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
set(CMAKE_Swift_MODULE_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/swiftmodules)
list(APPEND CMAKE_BUILD_RPATH "${CMAKE_LIBRARY_OUTPUT_DIRECTORY}")

add_compile_options($<$<COMPILE_LANGUAGE:Swift>:-warnings-as-errors>)

if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
  add_compile_options("$<$<COMPILE_LANGUAGE:Swift>:-target;x86_64-apple-macosx10.14>")
  # XXX: Workaround "Cannot load underlying module for Darwin"
  add_compile_options("$<$<COMPILE_LANGUAGE:Swift>:-sdk;${CMAKE_OSX_SYSROOT}>")
  set(CMAKE_INSTALL_RPATH "@executable_path/../lib/SwiftNIODemo")
endif()

# XXX: -O -gline-tables-only gets passed to executables but not to shared libraries
add_compile_options(
  "$<$<AND:$<CONFIG:Debug>,$<COMPILE_LANGUAGE:Swift>>:-g;-Onone;-assert-config;Debug>"
  "$<$<AND:$<CONFIG:RelWithDebugInfo>,$<COMPILE_LANGUAGE:Swift>>:-O;-gline-tables-only;-assert-config;Release>"
  "$<$<AND:$<CONFIG:Release>,$<COMPILE_LANGUAGE:Swift>>:-O;-assert-config;Release>"
)

### MARK - Targets
set(NIO_C_LIBRARIES
  CNIOAtomics
  CNIODarwin
  CNIOHTTPParser
  CNIOLinux
  CNIOSHA1
)
set(NIO_Swift_LIBRARIES
  _NIO1APIShims
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
  NIOUDPEchoClient
  NIOUDPEchoServer
  NIOWebSocketServer
)

# Boilerplate to match SwiftPM convention

foreach(nio_target IN LISTS NIO_DEMO_PROGRAMS NIO_Swift_LIBRARIES)
  file(GLOB_RECURSE ${nio_target}_SOURCES CONFIGURE_DEPENDS "Sources/${nio_target}/*.swift")
endforeach()

foreach(nio_program IN LISTS NIO_DEMO_PROGRAMS)
  add_executable(${nio_program} ${${nio_program}_SOURCES})
endforeach()

foreach(nio_library IN LISTS NIO_Swift_LIBRARIES)
  add_library(${nio_library} ${${nio_library}_SOURCES})
  target_include_directories(${nio_library} INTERFACE $<TARGET_PROPERTY:${nio_library},Swift_MODULE_DIRECTORY>)
endforeach()

foreach(subdir IN LISTS NIO_C_LIBRARIES)
  add_subdirectory(Sources/${subdir})
endforeach()

### MARK - Target Dependencies

target_link_libraries(_NIO1APIShims PUBLIC
  NIO
  NIOFoundationCompat
  NIOHTTP1
  NIOTLS
  NIOWebSocket
)

target_link_libraries(NIO PUBLIC
  CNIOAtomics
  CNIODarwin
  CNIOLinux
  CNIOSHA1
  NIOConcurrencyHelpers
)

target_link_libraries(NIOFoundationCompat PUBLIC NIO)
target_link_libraries(NIOConcurrencyHelpers PUBLIC CNIOAtomics)
target_link_libraries(NIOHTTP1 PUBLIC
  CNIOHTTPParser
  NIO
  NIOConcurrencyHelpers
)

target_link_libraries(NIOEchoClient NIO NIOConcurrencyHelpers)
target_link_libraries(NIOEchoServer NIO NIOConcurrencyHelpers)
target_link_libraries(NIOHTTP1Client NIO NIOHTTP1 NIOConcurrencyHelpers)
target_link_libraries(NIOHTTP1Server NIO NIOHTTP1 NIOConcurrencyHelpers)
target_link_libraries(NIOTLS PUBLIC NIO)
target_link_libraries(NIOChatClient NIO NIOConcurrencyHelpers)
target_link_libraries(NIOChatServer NIO NIOConcurrencyHelpers)
target_link_libraries(NIOWebSocket PUBLIC NIO NIOHTTP1 CNIOSHA1)
target_link_libraries(NIOWebSocketServer NIO NIOHTTP1 NIOWebSocket)
target_link_libraries(NIOPerformanceTester NIO NIOHTTP1 NIOFoundationCompat)
target_link_libraries(NIOMulticastChat NIO)
target_link_libraries(NIOUDPEchoClient NIO)
target_link_libraries(NIOUDPEchoServer NIO)
target_link_libraries(NIOTestUtils NIO)

### MARK - TODO: Test Targets

### MARK - Products

set(NIO_EXECUTABLE_PRODUCTS
  NIOChatClient
  NIOChatServer
  NIOEchoClient
  NIOEchoServer
  NIOHTTP1Client
  NIOHTTP1Server
  NIOMulticastChat
  NIOPerformanceTester
  NIOUDPEchoClient
  NIOUDPEchoServer
  NIOWebSocketServer
)
set(NIO_LIBRARY_PRODUCTS
  NIO
  _NIO1APIShims
  NIOTLS
  NIOHTTP1
  NIOConcurrencyHelpers
  NIOFoundationCompat
  NIOWebSocket
  NIOTestUtils
)

install(TARGETS ${NIO_EXECUTABLE_PRODUCTS} ${NIO_LIBRARY_PRODUCTS}
  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}/SwiftNIODemo
)

### MARK - Hacks

if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
  # XXX: CMake doesn't set LC_ID on Swift SHARED libraries, so we need to fix install_name here
  foreach(nio_library IN LISTS NIO_Swift_LIBRARIES)
    target_link_options(${nio_library} PRIVATE LINKER:-install_name,@rpath/$<TARGET_LINKER_FILE_NAME:${nio_library}>)
    target_link_options(${nio_library} INTERFACE LINKER:-rpath,@executable_path/../lib/${PROJECT_NAME})
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

### MARK - CMake Sanity Checks

# Sanity Check
file(GLOB NIO_MODULES "${CMAKE_CURRENT_LIST_DIR}/Sources/*")
foreach(nio_module IN LISTS NIO_MODULES)
  get_filename_component(nio_module "${nio_module}" NAME)
  if(NOT TARGET ${nio_module})
    message(WARNING "No CMake target for NIO module ${nio_module}")
  endif()
endforeach()

### MARK - Integration Tests

enable_testing()
add_subdirectory(IntegrationTests)
