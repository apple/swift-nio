/// An AsyncWriter provides an abstraction to write elements to an underlying sink.
public protocol AsyncWriter {
    associatedtype Element

    /// Writes the element to the underlying sink.
    mutating func write(_ element: consuming Element) async throws

    /// Finishes the underlying sink.
    ///
    /// This method is useful for sinks that support half-closure such as TCP or TLS 1.3.
    mutating func finish() async throws
}
