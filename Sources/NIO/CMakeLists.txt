add_library(NIO
  AddressedEnvelope.swift
  BSDSocketAPI.swift
  BaseSocket.swift
  BaseSocketChannel.swift
  BaseStreamSocketChannel.swift
  Bootstrap.swift
  ByteBuffer-aux.swift
  ByteBuffer-core.swift
  ByteBuffer-int.swift
  ByteBuffer-views.swift
  Channel.swift
  ChannelHandler.swift
  ChannelHandlers.swift
  ChannelInvoker.swift
  ChannelOption.swift
  ChannelPipeline.swift
  CircularBuffer.swift
  Codec.swift
  DatagramVectorReadManager.swift
  DeadChannel.swift
  Embedded.swift
  EventLoop.swift
  EventLoopFuture.swift
  FileDescriptor.swift
  FileHandle.swift
  FileRegion.swift
  GetaddrinfoResolver.swift
  HappyEyeballs.swift
  Heap.swift
  IntegerTypes.swift
  Interfaces.swift
  IO.swift
  IOData.swift
  Linux.swift
  LinuxCPUSet.swift
  MarkedCircularBuffer.swift
  MulticastChannel.swift
  NIOAny.swift
  NIOCloseOnErrorHandler.swift
  NIOThreadPool.swift
  NonBlockingFileIO.swift
  PendingDatagramWritesManager.swift
  PendingWritesManager.swift
  PipeChannel.swift
  PipePair.swift
  PriorityQueue.swift
  RecvByteBufferAllocator.swift
  Resolver.swift
  Selectable.swift
  SelectableEventLoop.swift
  Selector.swift
  ServerSocket.swift
  SingleStepByteToMessageDecoder.swift
  Socket.swift
  SocketAddresses.swift
  SocketChannel.swift
  SocketOptionProvider.swift
  SocketProtocols.swift
  Thread.swift
  ThreadPosix.swift
  ThreadWindows.swift
  TypeAssistedChannelHandler.swift
  UniversalBootstrapSupport.swift
  Utilities.swift)
target_compile_options(NIO PRIVATE
  $<$<BOOL:${BUILD_TESTING}>:-enable-testing>
  $<$<PLATFORM_ID:Windows>:-Xcc -D_CRT_SECURE_NO_WARNINGS>
  $<$<PLATFORM_ID:Windows>:-Xcc -D_CRT_NONSTDC_NO_WARNINGS>)
target_link_libraries(NIO PUBLIC
  # NOTE(compnerd) this is supposed to be kernelbase, but the import entry is
  # missing; use mincore instead.
  $<$<PLATFORM_ID:Windows>:mincore>
  $<$<PLATFORM_ID:Windows>:NIOModuleConstructor>
  swiftDispatch
  CNIOAtomics
  CNIODarwin
  CNIOLinux
  CNIOSHA1
  CNIOWindows
  NIOConcurrencyHelpers)
set_target_properties(NIO PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})
