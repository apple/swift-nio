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

add_library(NIOPosix
  "BSDSocketAPICommon.swift"
  "BSDSocketAPIPosix.swift"
  "BSDSocketAPIWindows.swift"
  "BaseSocket.swift"
  "BaseSocketChannel+AccessibleTransport.swift"
  "BaseSocketChannel+SocketOptionProvider.swift"
  "BaseSocketChannel.swift"
  "BaseStreamSocketChannel.swift"
  "Bootstrap.swift"
  "ControlMessage.swift"
  "DatagramVectorReadManager.swift"
  "Errors+Any.swift"
  "FileDescriptor.swift"
  "GetaddrinfoResolver.swift"
  "HappyEyeballs.swift"
  "IO.swift"
  "IntegerBitPacking.swift"
  "IntegerTypes.swift"
  "Linux.swift"
  "LinuxCPUSet.swift"
  "LinuxUring.swift"
  "MultiThreadedEventLoopGroup.swift"
  "NIOPosixSendableMetatype.swift"
  "NIORandomizedDNSResolver.swift"
  "NIOThreadPool.swift"
  "NonBlockingFileIO.swift"
  "PendingDatagramWritesManager.swift"
  "PendingWritesManager.swift"
  "PipeChannel.swift"
  "PipePair.swift"
  "Pool.swift"
  "PosixSingletons+ConcurrencyTakeOver.swift"
  "PosixSingletons.swift"
  "RawSocketBootstrap.swift"
  "Resolver.swift"
  "Selectable.swift"
  "SelectableChannel.swift"
  "SelectableEventLoop.swift"
  "SelectorEpoll.swift"
  "SelectorGeneric.swift"
  "SelectorKqueue.swift"
  "SelectorUring.swift"
  "SelectorWSAPoll.swift"
  "ServerSocket.swift"
  "Socket.swift"
  "SocketChannel.swift"
  "SocketProtocols.swift"
  "StructuredConcurrencyHelpers.swift"
  "System.swift"
  "Thread.swift"
  "ThreadPosix.swift"
  "ThreadWindows.swift"
  "Utilities.swift"
  "VsockAddress.swift"
  "VsockChannelEvents.swift"
  "Windows.swift"
)

# CNIOPosix holds thread-local state (the current event loop's ID and pointer). It is linked privately so
# that its archive, and with it that state, stays off the link lines of NIOPosix's consumers: only NIOPosix
# itself reaches it, through `inEventLoop`, which is `@usableFromInline` but not `@inlinable`. It is still
# forwarded as COMPILE_ONLY because NIOPosix is not built with library evolution, so its clients must be able
# to load CNIOPosix's module. Static builds still link the archive through the LINK_ONLY usage requirement.
target_link_libraries(NIOPosix
  PUBLIC
    $<$<NOT:$<PLATFORM_ID:Darwin>>:dispatch>
    CNIOOpenBSD
    CNIOLinux
    CNIODarwin
    CNIOWindows
    NIOConcurrencyHelpers
    NIOCore
    _NIODataStructures
    SwiftAtomics::Atomics
    SwiftCollections::DequeModule
  PRIVATE
    CNIOPosix
  INTERFACE
    $<COMPILE_ONLY:CNIOPosix>)

target_compile_options(NIOPosix PRIVATE ${SWIFT_NIO_COMPILE_OPTIONS})
target_compile_definitions(NIOPosix PRIVATE $<$<NOT:$<CONFIG:Release,RelWithDebInfo,MinSizeRel>>:DEBUG>)
set_target_properties(NIOPosix PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

swift_nio_install_target(NIOPosix)
set_property(GLOBAL APPEND PROPERTY SWIFT_NIO_EXPORTS NIOPosix)
