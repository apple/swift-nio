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

# The names of this file and of its functions are specific to SwiftNIO: CMake functions are global, so the
# `SwiftSupport.cmake`, `get_swift_host_os` and `_install_target` names that other packages use (with different
# definitions, for example in swift-collections) would collide when SwiftNIO vends its dependencies.

if(NOT SwiftNIO_SWIFTMODULE_TRIPLE)
  set(target_info_cmd "${CMAKE_Swift_COMPILER}" -print-target-info)
  if(CMAKE_Swift_COMPILER_TARGET)
    list(APPEND target_info_cmd -target ${CMAKE_Swift_COMPILER_TARGET})
  endif()
  execute_process(COMMAND ${target_info_cmd} OUTPUT_VARIABLE target_info)
  string(JSON module_triple GET "${target_info}" "target" "moduleTriple")
  set(SwiftNIO_SWIFTMODULE_TRIPLE "${module_triple}" CACHE STRING "Triple used to install Swift module files")
  mark_as_advanced(SwiftNIO_SWIFTMODULE_TRIPLE)
  message(CONFIGURE_LOG "Swift module triple: ${module_triple}")
endif()

# Returns the os name in a variable
#
# Usage:
#   swift_nio_get_swift_host_os(result_var_name)
#
#
# Sets ${result_var_name} with the converted OS name derived from
# CMAKE_SYSTEM_NAME.
function(swift_nio_get_swift_host_os result_var_name)
  if(CMAKE_SYSTEM_NAME STREQUAL Darwin)
    set(${result_var_name} macosx PARENT_SCOPE)
  else()
    string(TOLOWER ${CMAKE_SYSTEM_NAME} cmake_system_name_lc)
    set(${result_var_name} ${cmake_system_name_lc} PARENT_SCOPE)
  endif()
endfunction()

function(swift_nio_install_target module)
  swift_nio_get_swift_host_os(swift_os)
  get_target_property(type ${module} TYPE)

  if(type STREQUAL STATIC_LIBRARY)
    set(swift swift_static)
  else()
    set(swift swift)
  endif()

  install(TARGETS ${module}
    ARCHIVE DESTINATION lib/${swift}/${swift_os}
    LIBRARY DESTINATION lib/${swift}/${swift_os}
    RUNTIME DESTINATION bin)
  if(type STREQUAL EXECUTABLE)
    return()
  endif()

  get_target_property(module_name ${module} Swift_MODULE_NAME)
  if(NOT module_name)
    set(module_name ${module})
  endif()

  install(FILES $<TARGET_PROPERTY:${module},Swift_MODULE_DIRECTORY>/${module_name}.swiftdoc
    DESTINATION lib/${swift}/${swift_os}/${module_name}.swiftmodule
    RENAME ${SwiftNIO_SWIFTMODULE_TRIPLE}.swiftdoc)
  install(FILES $<TARGET_PROPERTY:${module},Swift_MODULE_DIRECTORY>/${module_name}.swiftmodule
    DESTINATION lib/${swift}/${swift_os}/${module_name}.swiftmodule
    RENAME ${SwiftNIO_SWIFTMODULE_TRIPLE}.swiftmodule)
endfunction()
