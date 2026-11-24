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

set(SWIFT_NIO_EXPORTS_FILE ${CMAKE_CURRENT_BINARY_DIR}/SwiftNIOExports.cmake)
configure_file(SwiftNIOConfig.cmake.in
    ${CMAKE_CURRENT_BINARY_DIR}/SwiftNIOConfig.cmake)

get_property(SWIFT_NIO_EXPORTS GLOBAL PROPERTY SWIFT_NIO_EXPORTS)
export(TARGETS ${SWIFT_NIO_EXPORTS} FILE ${SWIFT_NIO_EXPORTS_FILE})
