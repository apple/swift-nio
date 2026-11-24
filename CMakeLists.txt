##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

cmake_minimum_required(VERSION 3.29)

project(SwiftNIO
  LANGUAGES C Swift)

# SwiftNIO's headers use Clang's nullability qualifiers (`_Nonnull` and friends), which other C
# compilers reject, so fail early with a clear message rather than deep inside the build.
if(NOT CMAKE_C_COMPILER_ID MATCHES "Clang")
  message(FATAL_ERROR
    "SwiftNIO must be built with a Clang C compiler, but the C compiler is "
    "'${CMAKE_C_COMPILER}' (${CMAKE_C_COMPILER_ID}). Set CC=clang or pass "
    "-DCMAKE_C_COMPILER=<path to clang> when configuring.")
endif()

list(APPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_SOURCE_DIR}/cmake/modules)

include(SwiftNIOSupport)

option(BUILD_SHARED_LIBS "Build shared libraries by default" YES)

set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
set(CMAKE_Swift_MODULE_DIRECTORY ${CMAKE_BINARY_DIR}/swift)

set(SWIFT_NIO_COMPILE_OPTIONS
    -package-name swift-nio
    -enable-experimental-feature Lifetimes
    -enable-upcoming-feature MemberImportVisibility
)

set(CMAKE_POSITION_INDEPENDENT_CODE ${BUILD_SHARED_LIBS})

if(CMAKE_SYSTEM_NAME STREQUAL Darwin AND NOT CMAKE_CROSSCOMPILING)
  set(CMAKE_AR "/usr/bin/ar")
  set(CMAKE_C_ARCHIVE_CREATE "<CMAKE_AR> crs <TARGET> <LINK_FLAGS> <OBJECTS>")
  set(CMAKE_RANLIB "/usr/bin/ranlib")
endif()

if(CMAKE_SYSTEM_NAME STREQUAL Windows)
  # We can only link against the DLL version of the MSVC runtime library for now.
  set(CMAKE_Swift_COMPILE_OPTIONS_MSVC_RUNTIME_LIBRARY MultiThreadedDLL)
  set(CMAKE_MSVC_RUNTIME_LIBRARY MultiThreadedDLL)
  if(CMAKE_Swift_COMPILER_VERSION VERSION_EQUAL 0.0.0 OR CMAKE_Swift_COMPILER_VERSION VERSION_GREATER_EQUAL 6.2)
    # We need to set the static library prefix to "lib" so that we can link against the static libraries.
    set(CMAKE_STATIC_LIBRARY_PREFIX_Swift "lib")
  endif()
endif()

if(NOT CMAKE_SYSTEM_NAME STREQUAL Darwin)
  find_package(dispatch CONFIG)
  find_package(Foundation CONFIG)
endif()

include(FetchContent)

set(_NIO_SAVED_BUILD_EXAMPLES ${BUILD_EXAMPLES})
set(_NIO_SAVED_BUILD_TESTING ${BUILD_TESTING})
# swift-atomics builds its tests when BUILD_TESTING is on.
set(BUILD_TESTING NO)

find_package(swift-atomics CONFIG)
if(NOT swift-atomics_FOUND)
  message("-- Vending swift-atomics")
  FetchContent_Declare(SwiftAtomics
    GIT_REPOSITORY https://github.com/apple/swift-atomics
    GIT_TAG 1.3.1)
  FetchContent_MakeAvailable(SwiftAtomics)
endif()

find_package(SwiftCollections CONFIG)
if(NOT SwiftCollections_FOUND)
  message("-- Vending swift-collections")
  FetchContent_Declare(SwiftCollections
    GIT_REPOSITORY https://github.com/apple/swift-collections
    GIT_TAG 1.7.6)
  FetchContent_MakeAvailable(SwiftCollections)
endif()

find_package(SwiftSystem CONFIG)
if(NOT SwiftSystem_FOUND)
  message("-- Vending swift-system")
  FetchContent_Declare(SwiftSystem
    GIT_REPOSITORY https://github.com/apple/swift-system
    GIT_TAG 1.8.1)
  FetchContent_MakeAvailable(SwiftSystem)
endif()

set(BUILD_TESTING ${_NIO_SAVED_BUILD_TESTING})
set(BUILD_EXAMPLES ${_NIO_SAVED_BUILD_EXAMPLES})

# swift-collections can be built as a single module, which has no DequeModule target.
if(NOT TARGET SwiftCollections::DequeModule AND NOT TARGET DequeModule)
  message(FATAL_ERROR "SwiftNIO needs swift-collections' DequeModule target; COLLECTIONS_SINGLE_MODULE builds of swift-collections are not supported")
endif()

# find_package() provides namespaced targets whereas the vended dependencies only provide plain ones.
# Always link against the namespaced names.
if(NOT TARGET SwiftAtomics::Atomics)
  add_library(SwiftAtomics::Atomics ALIAS Atomics)
endif()
if(NOT TARGET SwiftCollections::DequeModule)
  add_library(SwiftCollections::DequeModule ALIAS DequeModule)
endif()
if(NOT TARGET SwiftSystem::SystemPackage)
  add_library(SwiftSystem::SystemPackage ALIAS SystemPackage)
endif()

# Set after vending the dependencies so their targets keep their own language mode.
set(CMAKE_Swift_LANGUAGE_VERSION 6)

add_subdirectory(Sources)
add_subdirectory(cmake/modules)
