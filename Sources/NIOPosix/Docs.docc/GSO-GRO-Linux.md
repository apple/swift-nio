# Per-Message GSO and GRO on Linux

Use Generic Segmentation Offload (GSO) and Generic Receive Offload (GRO) on a per-message basis for fine-grained control over UDP datagram segmentation and aggregation.

## Overview

Generic Segmentation Offload (GSO) and Generic Receive Offload (GRO) are Linux kernel features that enable efficient handling of UDP datagrams by offloading segmentation and aggregation work to the kernel or network interface card (NIC).

SwiftNIO provides per-message APIs for both features, allowing dynamic control over segmentation and aggregation on a datagram-by-datagram basis. This offers more flexibility than channel-wide configuration, which requires static segment sizes known ahead of time.

### What is Generic Segmentation Offload (GSO)?

GSO allows you to send a single large buffer (a "superbuffer") that the kernel automatically splits into multiple UDP datagrams of a specified segment size. Instead of your application creating many small datagrams, you write one superbuffer and let the kernel handle the segmentation efficiently.

**Benefits:**
- Reduced application overhead by avoiding manual buffer segmentation
- Lower CPU usage as the kernel or NIC performs the segmentation
- Improved throughput for high-volume UDP applications

### What is Generic Receive Offload (GRO)?

GRO is the reverse of GSO: the kernel aggregates multiple received UDP datagrams into a single larger buffer (again, a "superbuffer") before delivering it to your application. When enabled with per-message metadata, you receive information about the original segment size used for aggregation.

**Benefits:**
- Fewer read syscalls and event loop iterations
- Reduced per-packet processing overhead
- Better performance for applications receiving many small datagrams

## Per-Message GSO

The per-message GSO API allows you to specify segmentation parameters for each datagram write, rather than configuring a static segment size for the entire channel.

### Enabling Per-Message GSO

To use per-message GSO, set the `segmentSize` field in `AddressedEnvelope.Metadata` when writing datagrams:

```swift
import NIOCore
import NIOPosix

// Create a large buffer to send (10 segments of 1000 bytes each)
let segmentSize = 1000
let segmentCount = 10
var largeBuffer = channel.allocator.buffer(capacity: segmentSize * segmentCount)
largeBuffer.writeRepeatingByte(1, count: segmentSize * segmentCount)

// Write with per-message GSO metadata
let envelope = AddressedEnvelope(
    remoteAddress: destinationAddress,
    data: largeBuffer,
    metadata: .init(
        ecnState: .transportNotCapable,
        packetInfo: nil,
        segmentSize: segmentSize  // Enable GSO with 1000-byte segments
    )
)

try await channel.writeAndFlush(envelope)
```

The kernel will automatically split `largeBuffer` into 10 separate UDP datagrams of 1000 bytes each.

### Mixing GSO and Non-GSO Writes

You can freely mix writes with and without per-message GSO on the same channel:

```swift
// Write with GSO
let gsoEnvelope = AddressedEnvelope(
    remoteAddress: destinationAddress,
    data: largeBuffer,
    metadata: .init(ecnState: .transportNotCapable, packetInfo: nil, segmentSize: 1000)
)

// Write without GSO (normal datagram)
let normalEnvelope = AddressedEnvelope(
    remoteAddress: destinationAddress,
    data: smallBuffer
)

let write1 = channel.write(gsoEnvelope)
let write2 = channel.write(normalEnvelope)
channel.flush()
```

## Per-Message GRO

The per-message GRO API provides segment size information for each received aggregated datagram through the same `AddressedEnvelope.Metadata.segmentSize` field used for GSO.

### Enabling Per-Message GRO

To enable per-message GRO segment size reporting, you must:

1. Enable channel-level GRO using `ChannelOptions.datagramReceiveOffload`
2. Enable per-message segment size reporting using `ChannelOptions.datagramReceiveSegmentSize`
3. Configure an appropriate receive buffer allocator to accommodate aggregated datagrams

```swift
import NIOCore
import NIOPosix

// Enable GRO on the channel
try await channel.setOption(.datagramReceiveOffload, value: true)

// Enable per-message segment size reporting
try await channel.setOption(.datagramReceiveSegmentSize, value: true)

// Configure a larger receive buffer to accommodate aggregated datagrams
let largeBufferAllocator = FixedSizeRecvByteBufferAllocator(capacity: 65536)
try await channel.setOption(.recvAllocator, value: largeBufferAllocator)
```

### Reading Segment Size from Received Datagrams

When you receive an aggregated datagram, the `segmentSize` field in the metadata contains the original segment size:

```swift
// In your channel handler
func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let envelope = self.unwrapInboundIn(data)

    // Check if this is an aggregated datagram
    if let segmentSize = envelope.metadata?.segmentSize {
        print("Received aggregated datagram:")
        print("  Total size: \(envelope.data.readableBytes) bytes")
        print("  Original segment size: \(segmentSize) bytes")
        print("  Approximate segment count: \(envelope.data.readableBytes / segmentSize)")
    } else {
        print("Received normal datagram: \(envelope.data.readableBytes) bytes")
    }
}
```

### Buffer Allocator Considerations

When using GRO, ensure your receive buffer allocator provides buffers large enough to hold aggregated datagrams. The default datagram channel allocator uses 2048-byte fixed buffers, which may be too small:

```swift
// Instead of the default 2048-byte buffers, use larger buffers
let allocator = FixedSizeRecvByteBufferAllocator(capacity: 65536)  // 64KB buffers
try await channel.setOption(.recvAllocator, value: allocator)
```

If the receive buffer is too small, the kernel will not be able to aggregate as many datagrams, reducing the effectiveness of GRO.

## Platform Requirements and Limitations

### Linux-Only Feature

Per-message GSO and GRO are only supported on Linux. Attempting to use these features on other platforms will result in errors:

- **GSO**: Writing an envelope with `segmentSize` set will fail the write promise with `ChannelError.operationUnsupported`
- **GRO**: Setting `ChannelOptions.datagramReceiveSegmentSize` will fail with `ChannelError.operationUnsupported`

### Kernel Version Requirements

- **GSO**: Requires Linux kernel 4.18 or newer
- **GRO**: Requires Linux kernel 5.10 or newer

### Runtime Support Detection

Check for GSO and GRO support at runtime using the `System` APIs:

```swift
import NIOPosix

if System.supportsUDPSegmentationOffload {
    print("GSO is supported on this platform")
    // Use per-message GSO
} else {
    print("GSO is not supported, falling back to normal writes")
}

if System.supportsUDPReceiveOffload {
    print("GRO is supported on this platform")
    // Enable per-message GRO
} else {
    print("GRO is not supported")
}
```

### Error Handling

Generally speaking, error handling for GSO and GRO is very similar to the error handling without them. An important note is that a single promise cannot handle individualised errors for the datagrams within the superbuffer. The kernel delivers only one return code for a given send or receive, which affects multiple datagrams within the superbuffer. However, it may not affect _all_ datagrams within the superbuffer,
as the writes can be split. The result is that if the _final_ superbuffer write completes successfully the
promise will be succeeded, even if errors occurred earlier.

In the event that you do not follow the steps above and attempt to use GSO on platforms that do not support it, the promise will fail with `.operationUnsupported` and no writes will be attempted.
