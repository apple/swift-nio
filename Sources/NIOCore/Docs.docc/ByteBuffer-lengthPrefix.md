# Writing length-prefixed data in ByteBuffer

This article explains how to write data prefixed with a length, where the length could be encoded in various ways.

## Overview

We often need to write some data prefixed by its length. Sometimes, this may simply be a fixed width integer. But many
protocols encode the length differently, depending on how big it is. For example, the QUIC protocol uses variable-length
integer encodings, in which smaller numbers can be encoded in fewer bytes.

We have added functions to help with reading and writing data which is prefixed with lengths encoded by various
strategies.

## ``NIOBinaryIntegerEncodingStrategy`` protocol

The first building block is a protocol which describes how to encode and decode an integer.

An implementation of this protocol is needed for any encoding strategy. One example is the ``ByteBuffer/QUICBinaryEncodingStrategy``.

This protocol only has two requirements which don't have default implementations:

- `readInteger`: Reads an integer from the `ByteBuffer` using this encoding. Implementations will read as many bytes as
  they need to, according to their wire format, and move the reader index accordingly
- `writeInteger`: Write an integer to the `ByteBuffer` using this encoding. Implementations will write as many bytes as
  they need to, according to their wire format, and move the writer index accordingly.

Note that implementations of this protocol need to either:

- Encode the length of the integer into the integer itself when writing, so it knows how many bytes to read when
  reading. This is what QUIC does.
- Always use the same length, e.g. a simple strategy which always writes the integer as a `UInt64`.

## Extensions on ``ByteBuffer``

To provide a more user-friendly API, we have added extensions on `ByteBuffer` for writing integers with a
chosen ``NIOBinaryIntegerEncodingStrategy``. These are ``ByteBuffer/writeEncodedInteger(_:strategy:)``
and ``ByteBuffer/readEncodedInteger(as:strategy:)``.

## Reading and writing length-prefixed data

We added further APIs on ByteBuffer for reading data, strings and buffers which are written with a length prefix. These
APIs first read an integer using a chosen encoding strategy. The integer then dictates how many bytes of data are read
starting from after the integer.

Similarly, there are APIs which take data, write its length using the provided strategy, and then write the data itself.

## Writing complex data with a length-prefix

Consider the scenario where we want to write multiple pieces of data with a length-prefix, but it is difficult or
complex to work out the total length of that data.

We decided to add the following API to ByteBuffer:

```swift
/// - Parameters:
///   - strategy: The strategy to use for encoding the length.
///   - writeData: A closure that takes a buffer, writes some data to it, and returns the number of bytes written.
/// - Returns: Number of total bytes written. This is the length of the written data + the number of bytes used to write the length before it.
public mutating func writeLengthPrefixed<Strategy: NIOBinaryIntegerEncodingStrategy, ErrorType: Error>(
    strategy: Strategy,
    writeData: (_ buffer: inout ByteBuffer) throws(ErrorType) -> Int
) throws(ErrorType) -> Int
```

Users could use the function as follows:

```swift
myBuffer.writeLengthPrefixed(strategy: .quic) { buffer in
    buffer.writeString("something")
    buffer.writeSomethingComplex(something)
}
```

Writing the implementation of `writeLengthPrefixed` presents a challenge. We need to write the length _before_ the
data. But we do not know the length until the data is written.

Ideally, we would reserve some number of bytes, then call the `writeData` closure, and then go back and write the length
in the reserved space. However, we would not even know how many bytes of space to reserve, because the number of bytes
needed to write an integer will depend on the integer!

The solution we landed on is the following:

- Added ``NIOBinaryIntegerEncodingStrategy/requiredBytesHint``. This allows strategies to provide an estimate of how
  many bytes they need for encoding a length
- Using this property, reserve the estimated number of bytes
- Call the `writeData` closure to write the data
- Go back to the reserved space to write the length
    - If the length ends up needing fewer bytes than we had reserved, shuffle the data back to close the gap
    - If the length ends up needing more bytes than we had reserved, shuffle the data forward to make space

This code will be most performant when the `requiredBytesHint` is exactly correct, because it will avoid needing to
shuffle any bytes. With that in mind, we can actually make one more optimisation: when we call the `writeInteger` function
on a strategy, we can tell the strategy that we have already reserved some number of bytes. Some encoding strategies
will be able to adjust the way they encode such that they can use exactly that many bytes.

We added the following function to the ``NIOBinaryIntegerEncodingStrategy`` protocol. This is optional to implement, and
will default to simply calling the existing ``NIOBinaryIntegerEncodingStrategy/writeInteger(_:to:)`` function.

```swift
/// - Parameters:
///   - integer: The integer to write
///   - reservedCapacity: The capacity already reserved for writing this integer
///   - buffer: The buffer to write into.
/// - Returns: The number of bytes used to write the integer.
func writeInteger(
    _ integer: Int,
    reservedCapacity: Int,
    to buffer: inout ByteBuffer
) -> Int
```

Many strategies will not be able to do anything useful with the additional `reservedCapacity` parameter. For example, in
ASN1, there is only one possible encoding for a given integer. However, some protocols, such as QUIC, do allow less
efficient encodings. E.g. it is valid in QUIC to encode the number `6` using 4 bytes, even though it could be encoded
using just 1. Such encoding strategies need to make a decision here: they can either use the less efficient
encoding (and therefore use more bytes to encode the integer than would otherwise be necessary), or they can use the
more efficient encoding (and therefore suffer a performance penalty as the bytes need to be shuffled).
