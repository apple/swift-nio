Swift NIO Optimization Tips
===========================

The following document is a list of tips and advice for writing high performance
code using Swift NIO.

General Optimization Tips
-------------------------

Although not specific to NIO, the [Swift GitHub repository][swift-repo] has a
list of tips and tricks for [writing high performance Swift code][swift-optimization-tips]
and is a great place to start.

Wrapping types in `NIOAny`
--------------------------

Anything passing through a NIO pipeline that is not special-cased by `NIOAny`
(i.e. is not one of `ByteBuffer`, `FileRegion`, `IOData` or
`AddressedEnvelope<ByteBuffer>`) needs to have careful attention paid to its
size. If the type isn't one of the aforementioned special cases then it must be
no greater than 24 bytes in size to avoid a heap-allocation each time it is
added to a `NIOAny`. The size of a type can be checked using
[`MemoryLayout.size`][docs-memory-layout].

If the type being wrapped is a value type then it can be narrowed by placing it
in a copy-on-write box. Alternatively, if the type is an `enum` with associated
data, then it is possible for the associated data to be boxed by the compiler by
making it an `indirect case`.


[swift-repo]: https://github.com/apple/swift
[swift-optimization-tips]: https://github.com/apple/swift/blob/main/docs/OptimizationTips.rst
[docs-memory-layout]: https://developer.apple.com/documentation/swift/memorylayout
