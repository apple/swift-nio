@usableFromInline
internal struct _ByteBufferGuts {
    @usableFromInline
    internal var _storage: _ByteBufferStorage
    
    @inlinable
    internal init(_ storage: _ByteBufferStorage) {
        self._storage = storage
    }
}

extension _ByteBufferGuts {
    @inlinable
    var capacity: Int {
        return self._storage.capacity
    }
    
    @inlinable
    mutating func isUniquelyOwned() -> Bool {
        return isKnownUniquelyReferenced(&self._storage)
    }
}

extension _ByteBufferGuts {
    @inlinable
    internal mutating func _checkInvariants() {
        assert(isKnownUniquelyReferenced(&self._storage))
        assert(self.capacity == self._storage.header.capacity)
    }
}

extension _ByteBufferGuts {
    @inline(never) @usableFromInline
    internal mutating func _slowPath_allocateNewStorage(_ guts: _ByteBufferGuts, slice: _ByteBufferSlice) -> _ByteBufferGuts {
        var newGuts = _ByteBufferGuts(.make(slice.count))
        guts._storage.withUnsafeBytes { ptr in
            newGuts.copyBytes(from: .init(rebasing: ptr[Int(slice.lowerBound) ..< Int(slice.upperBound)]), toIndex: 0)
        }
        return newGuts
    }

    @inline(never) @usableFromInline
    internal mutating func _slowPath_increaseCapacity(_ newCapacity: Int) {
        self._checkInvariants()
        if tryReallocateUniquelyReferenced(buffer: &self._storage, newMinimumCapacity: newCapacity) {
            self._checkInvariants()
            assert(newCapacity != self.capacity)
            self._storage.header.capacity = newCapacity
            self._checkInvariants()
        } else {
            // TODO: This can't be right (fullSlice)
            self = self._slowPath_allocateNewStorage(self, slice: self.fullSlice)
        }
    }
    
    @inlinable
    internal mutating func reserveCapacity(_ newCapacity: Int) {
        guard newCapacity > self.capacity else {
            return
        }
        self._slowPath_increaseCapacity(newCapacity)
    }
}

extension _ByteBufferGuts {
    @inlinable
    internal mutating func copyBytes(from src: UnsafeRawBufferPointer, toIndex: Int) {
        self._storage.withUnsafeMutableBytes { wholeDest in
            let dest = UnsafeMutableRawBufferPointer(rebasing: wholeDest[toIndex...])
            dest.copyBytes(from: src)
        }
    }
}

extension _ByteBufferGuts {
    public func dumpBytes(slice: _ByteBufferSlice, offset: Int, length: Int) -> String {
        var desc = "["
        self._storage.withUnsafeBytes { bytes in
            for byte in bytes[Int(slice.lowerBound) + offset ..< Int(slice.lowerBound) + offset + length] {
                let hexByte = String(byte, radix: 16)
                desc += " \(hexByte.count == 1 ? "0" : "")\(hexByte)"
            }
        }
        desc += " ]"
        return desc
    }
}
