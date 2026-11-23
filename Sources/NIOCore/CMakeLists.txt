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

add_library(NIOCore
  "AddressedEnvelope.swift"
  "AsyncAwaitSupport.swift"
  "AsyncChannel/AsyncChannel.swift"
  "AsyncChannel/AsyncChannelHandler.swift"
  "AsyncChannel/AsyncChannelInboundStream.swift"
  "AsyncChannel/AsyncChannelOutboundWriter.swift"
  "AsyncSequences/NIOAsyncSequenceProducer.swift"
  "AsyncSequences/NIOAsyncSequenceProducerStrategies.swift"
  "AsyncSequences/NIOAsyncWriter.swift"
  "AsyncSequences/NIOThrowingAsyncSequenceProducer.swift"
  "BSDSocketAPI.swift"
  "ByteBuffer-aux.swift"
  "ByteBuffer-binaryEncodedLengthPrefix.swift"
  "ByteBuffer-conversions.swift"
  "ByteBuffer-core.swift"
  "ByteBuffer-hex.swift"
  "ByteBuffer-int.swift"
  "ByteBuffer-lengthPrefix.swift"
  "ByteBuffer-multi-int.swift"
  "ByteBuffer-quicBinaryEncodingStrategy.swift"
  "ByteBuffer-views.swift"
  "Channel.swift"
  "ChannelHandler.swift"
  "ChannelHandlers.swift"
  "ChannelInvoker.swift"
  "ChannelOption.swift"
  "ChannelPipeline.swift"
  "CircularBuffer.swift"
  "Codec.swift"
  "ConvenienceOptionSupport.swift"
  "DeadChannel.swift"
  "DispatchQueue+WithFuture.swift"
  "EventLoop+Deprecated.swift"
  "EventLoop+SerialExecutor.swift"
  "EventLoop.swift"
  "EventLoopFuture+AssumeIsolated.swift"
  "EventLoopFuture+Deprecated.swift"
  "EventLoopFuture+WithEventLoop.swift"
  "EventLoopFuture.swift"
  "FileDescriptor.swift"
  "FileHandle.swift"
  "FileRegion.swift"
  "GlobalSingletons.swift"
  "IO.swift"
  "IOData.swift"
  "IPProtocol.swift"
  "IntegerBitPacking.swift"
  "IntegerTypes.swift"
  "Interfaces.swift"
  "Linux.swift"
  "MarkedCircularBuffer.swift"
  "MulticastChannel.swift"
  "NIOAny.swift"
  "NIOCloseOnErrorHandler.swift"
  "NIOCoreSendableMetatype.swift"
  "NIODecodedAsyncSequence.swift"
  "NIOLoopBound.swift"
  "NIOPooledRecvBufferAllocator.swift"
  "NIOScheduledCallback.swift"
  "NIOSendable.swift"
  "NIOSplitLinesMessageDecoder.swift"
  "NIOTransportAccessibleChannelCore.swift"
  "RecvByteBufferAllocator.swift"
  "SingleStepByteToMessageDecoder.swift"
  "SocketAddresses.swift"
  "SocketOptionProvider.swift"
  "SystemCallHelpers.swift"
  "TimeAmount+Duration.swift"
  "TypeAssistedChannelHandler.swift"
  "UniversalBootstrapSupport.swift"
  "Utilities.swift"
)

target_link_libraries(NIOCore PUBLIC
  $<$<NOT:$<PLATFORM_ID:Darwin>>:dispatch>
  NIOConcurrencyHelpers
  _NIOBase64
  _NIODataStructures
  CNIOOpenBSD
  CNIOFreeBSD
  CNIODarwin
  CNIOLinux
  CNIOWindows
  CNIOWASI
  SwiftCollections::DequeModule
  SwiftAtomics::Atomics)

target_compile_options(NIOCore PRIVATE ${SWIFT_NIO_COMPILE_OPTIONS})
target_compile_definitions(NIOCore PRIVATE $<$<NOT:$<CONFIG:Release,RelWithDebInfo,MinSizeRel>>:DEBUG>)
set_target_properties(NIOCore PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

swift_nio_install_target(NIOCore)
set_property(GLOBAL APPEND PROPERTY SWIFT_NIO_EXPORTS NIOCore)
