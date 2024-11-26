# ``NIOCore``

The core abstractions that make up SwiftNIO.

## Overview

``NIOCore`` contains the fundamental abstractions that are used in all SwiftNIO programs. The goal of this module is to
be platform-independent, and to be the most-common building block used for NIO protocol implementations.

More specialized modules provide concrete implementations of many of the abstractions defined in NIOCore.

## Topics

### Articles

- <doc:swift-concurrency>
- <doc:ByteBuffer-lengthPrefix>
- <doc:loops-futures-concurrency>

### Event Loops and Event Loop Groups

- ``EventLoopGroup``
- ``EventLoop``
- ``EventLoopIterator``
- ``Scheduled``
- ``RepeatedTask``
- ``NIOLoopBound``
- ``NIOLoopBoundBox``

### Channels and Channel Handlers

- ``Channel``
- ``MulticastChannel``
- ``ChannelHandler``
- ``ChannelOutboundHandler``
- ``ChannelInboundHandler``
- ``ChannelDuplexHandler``
- ``ChannelHandlerContext``
- ``ChannelPipeline``
- ``RemovableChannelHandler``
- ``NIOAny``
- ``ChannelEvent``
- ``CloseMode``
- ``ChannelShouldQuiesceEvent``

### Buffers and Files

- ``ByteBuffer``
- ``ByteBufferView``
- ``ByteBufferAllocator``
- ``Endianness``
- ``NIOFileHandle``
- ``FileDescriptor``
- ``FileRegion``
- ``NIOPOSIXFileMode``
- ``IOData``

### Futures and Promises

- ``EventLoopFuture``
- ``EventLoopPromise``

### Configuring Channels

- ``ChannelOption``
- ``NIOSynchronousChannelOptions``
- ``ChannelOptions``
- ``SocketOptionProvider``
- ``RecvByteBufferAllocator``
- ``AdaptiveRecvByteBufferAllocator``
- ``FixedSizeRecvByteBufferAllocator``
- ``AllocatorOption``
- ``AllowRemoteHalfClosureOption``
- ``AutoReadOption``
- ``BacklogOption``
- ``ConnectTimeoutOption``
- ``DatagramVectorReadMessageCountOption``
- ``MaxMessagesPerReadOption``
- ``RecvAllocatorOption``
- ``SocketOption``
- ``SocketOptionLevel``
- ``SocketOptionName``
- ``SocketOptionValue``
- ``WriteBufferWaterMarkOption``
- ``WriteBufferWaterMark``
- ``WriteSpinOption``

### Message Oriented Protocol Helpers

- ``AddressedEnvelope``
- ``NIOPacketInfo``
- ``NIOExplicitCongestionNotificationState``

### Generic Bootstraps

- ``NIOClientTCPBootstrap``
- ``NIOClientTCPBootstrapProtocol``
- ``NIOClientTLSProvider``
- ``NIOInsecureNoTLS``

### Simple Message Handling

- ``ByteToMessageDecoder``
- ``WriteObservingByteToMessageDecoder``
- ``DecodingState``
- ``ByteToMessageHandler``
- ``NIOSingleStepByteToMessageDecoder``
- ``NIOSingleStepByteToMessageProcessor``
- ``MessageToByteEncoder``
- ``MessageToByteHandler``

### Core Channel Handlers

- ``AcceptBackoffHandler``
- ``BackPressureHandler``
- ``NIOCloseOnErrorHandler``
- ``IdleStateHandler``

### Async Sequences

- ``NIOAsyncSequenceProducer``
- ``NIOThrowingAsyncSequenceProducer``
- ``NIOAsyncSequenceProducerBackPressureStrategy``
- ``NIOAsyncSequenceProducerBackPressureStrategies``
- ``NIOAsyncSequenceProducerDelegate``
- ``NIOAsyncWriter``
- ``NIOAsyncWriterSinkDelegate``

### Time

- ``TimeAmount``
- ``NIODeadline``

### Circular Buffers

- ``CircularBuffer``
- ``MarkedCircularBuffer``

### Operating System State

- ``System``
- ``NIONetworkDevice``
- ``NIONetworkInterface``
- ``SocketAddress``
- ``NIOBSDSocket``
- ``NIOIPProtocol``

### Implementing Core Abstractions

- ``ChannelCore``
- ``ChannelInvoker``
- ``ChannelInboundInvoker``
- ``ChannelOutboundInvoker``

### Sendable Helpers

- ``NIOSendable``
- ``NIOPreconcurrencySendable``

### Error Types

- ``ByteToMessageDecoderError``
- ``ChannelError``
- ``ChannelPipelineError``
- ``DatagramChannelError``
- ``EventLoopError``
- ``IOError``
- ``NIOAsyncWriterError``
- ``NIOAttemptedToRemoveHandlerMultipleTimesError``
- ``NIOMulticastNotImplementedError``
- ``NIOMulticastNotSupportedError``
- ``NIOTooManyBytesError``
- ``SocketAddressError``

