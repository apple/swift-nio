@usableFromInline
internal struct StorageCapacity {
    @usableFromInline
    internal var capacity: Int
}

@usableFromInline
internal final class _ByteBufferStorage: ManagedBuffer<StorageCapacity, UInt8> {
    @usableFromInline
    internal class func make(_ capacity: Int) -> _ByteBufferStorage {
        let r = super.create(minimumCapacity: capacity) {
            StorageCapacity(capacity: $0.capacity)
        }
        return r as! _ByteBufferStorage
    }
}

extension _ByteBufferStorage {
    @inlinable
    internal func withUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows  -> T {
        return try self.withUnsafeMutablePointerToElements { ptr in
            try body(.init(start: ptr, count: self.capacity))
        }
    }
    
    @inlinable
    internal func withUnsafeMutableBytes<T>(_ body: (UnsafeMutableRawBufferPointer) throws -> T) rethrows -> T {
        return try self.withUnsafeMutablePointerToElements { ptr in
            try body(.init(start: ptr, count: self.capacity))
        }
    }
}
