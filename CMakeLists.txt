cmake_minimum_required(VERSION 3.16.0)

project(NIO
  LANGUAGES C Swift)

include(CTest)

set(CMAKE_Swift_MODULE_DIRECTORY ${CMAKE_BINARY_DIR}/swift)

set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)

find_package(dispatch CONFIG QUIET)
find_package(Foundation CONFIG QUIET)

add_subdirectory(Sources)
if(BUILD_TESTING)
  find_package(XCTest CONFIG QUIET)
  add_subdirectory(Tests)
endif()
