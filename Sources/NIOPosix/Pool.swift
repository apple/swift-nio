//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

protocol PoolElement {
    init()
    func evictedFromPool()
}

class Pool<Element: PoolElement> {
    private let maxSize: Int
    private var elements: [Element]

    init(maxSize: Int) {
        self.maxSize = maxSize
        self.elements = [Element]()
    }

    deinit {
        for e in elements {
            e.evictedFromPool()
        }
    }

    func get() -> Element {
        if elements.isEmpty {
            return Element()
        } else {
            return elements.removeLast()
        }
    }

    func put(_ e: Element) {
        if elements.count == maxSize {
            e.evictedFromPool()
        } else {
            elements.append(e)
        }
    }
}

/// A ``PooledBuffer`` is used to track an allocation of memory required
/// by a `Channel` or `EventLoopGroup`.
///
/// ``PooledBuffer`` is a reference type with inline storage. It is intended to
/// be bound to a single thread, and ensures that the allocation it stores does not
/// get freed before the buffer is out of use.
struct PooledBuffer: PoolElement {
    private static let sentinelValue = MemorySentinel(0xdead_beef)

    private let storage: BackingStorage

    init() {
        self.storage = .create(iovectorCount: Socket.writevLimitIOVectors)
        self.configureSentinel()
    }

    func evictedFromPool() {
        self.validateSentinel()
    }

    func withUnsafePointers<ReturnValue>(
        _ body: (UnsafeMutableBufferPointer<IOVector>, UnsafeMutableBufferPointer<Unmanaged<AnyObject>>) throws ->
            ReturnValue
    ) rethrows -> ReturnValue {
        defer {
            self.validateSentinel()
        }
        return try self.storage.withUnsafeMutableTypedPointers { iovecPointer, ownerPointer, _ in
            try body(iovecPointer, ownerPointer)
        }
    }

    /// Yields buffer pointers containing this ``PooledBuffer``'s readable bytes. You may hold a pointer to those bytes
    /// even after the closure has returned iff you model the lifetime of those bytes correctly using the `Unmanaged`
    /// instance. If you don't require the pointer after the closure returns, use ``withUnsafePointers``.
    ///
    /// If you escape the pointer from the closure, you _must_ call `storageManagement.retain()` to get ownership to
    /// the bytes and you also must call `storageManagement.release()` if you no longer require those bytes. Calls to
    /// `retain` and `release` must be balanced.
    ///
    /// - Parameters:
    ///   - body: The closure that will accept the yielded pointers and the `storageManagement`.
    /// - Returns: The value returned by `body`.
    func withUnsafePointersWithStorageManagement<ReturnValue>(
        _ body: (
            UnsafeMutableBufferPointer<IOVector>, UnsafeMutableBufferPointer<Unmanaged<AnyObject>>, Unmanaged<AnyObject>
        ) throws -> ReturnValue
    ) rethrows -> ReturnValue {
        let storageRef: Unmanaged<AnyObject> = Unmanaged.passUnretained(self.storage)
        return try self.storage.withUnsafeMutableTypedPointers { iovecPointer, ownerPointer, _ in
            try body(iovecPointer, ownerPointer, storageRef)
        }
    }

    private func configureSentinel() {
        self.storage.withUnsafeMutableTypedPointers { _, _, sentinelPointer in
            sentinelPointer.pointee = Self.sentinelValue
        }
    }

    private func validateSentinel() {
        self.storage.withUnsafeMutableTypedPointers { _, _, sentinelPointer in
            precondition(sentinelPointer.pointee == Self.sentinelValue, "Detected memory handling error!")
        }
    }
}

extension PooledBuffer {
    fileprivate typealias MemorySentinel = UInt32

    fileprivate struct PooledBufferHead {
        let iovectorCount: Int

        let spaceForIOVectors: Int

        let spaceForBufferOwners: Int

        init(iovectorCount: Int) {
            var spaceForIOVectors = MemoryLayout<IOVector>.stride * iovectorCount
            spaceForIOVectors.roundUpToAlignment(for: Unmanaged<AnyObject>.self)

            var spaceForBufferOwners = MemoryLayout<Unmanaged<AnyObject>>.stride * iovectorCount
            spaceForBufferOwners.roundUpToAlignment(for: MemorySentinel.self)

            self.iovectorCount = iovectorCount
            self.spaceForIOVectors = spaceForIOVectors
            self.spaceForBufferOwners = spaceForBufferOwners
        }

        var totalByteCount: Int {
            self.spaceForIOVectors + self.spaceForBufferOwners + MemoryLayout<MemorySentinel>.size
        }

        var iovectorOffset: Int {
            0
        }

        var bufferOwnersOffset: Int {
            self.spaceForIOVectors
        }

        var memorySentinelOffset: Int {
            self.spaceForIOVectors + self.spaceForBufferOwners
        }
    }

    fileprivate final class BackingStorage: ManagedBuffer<PooledBufferHead, UInt8> {
        static func create(iovectorCount: Int) -> Self {
            let head = PooledBufferHead(iovectorCount: iovectorCount)

            let baseStorage = Self.create(minimumCapacity: head.totalByteCount) { _ in
                head
            }

            // Here we set up our memory bindings.

            // Intentionally using a force cast here to avoid a miss compiliation in 5.10.
            // This is as fast as an unsafeDownCast since ManagedBuffer is inlined and the optimizer
            // can eliminate the upcast/downcast pair
            let storage = baseStorage as! Self
            storage.withUnsafeMutablePointers { headPointer, tailPointer in
                UnsafeRawPointer(tailPointer + headPointer.pointee.iovectorOffset).bindMemory(
                    to: IOVector.self,
                    capacity: iovectorCount
                )
                UnsafeRawPointer(tailPointer + headPointer.pointee.bufferOwnersOffset).bindMemory(
                    to: Unmanaged<AnyObject>.self,
                    capacity: iovectorCount
                )
                UnsafeRawPointer(tailPointer + headPointer.pointee.memorySentinelOffset).bindMemory(
                    to: MemorySentinel.self,
                    capacity: 1
                )
            }

            return storage
        }

        func withUnsafeMutableTypedPointers<ReturnType>(
            _ body: (
                UnsafeMutableBufferPointer<IOVector>, UnsafeMutableBufferPointer<Unmanaged<AnyObject>>,
                UnsafeMutablePointer<MemorySentinel>
            ) throws -> ReturnType
        ) rethrows -> ReturnType {
            try self.withUnsafeMutablePointers { headPointer, tailPointer in
                let iovecPointer = UnsafeMutableRawPointer(tailPointer + headPointer.pointee.iovectorOffset)
                    .assumingMemoryBound(to: IOVector.self)
                let ownersPointer = UnsafeMutableRawPointer(tailPointer + headPointer.pointee.bufferOwnersOffset)
                    .assumingMemoryBound(to: Unmanaged<AnyObject>.self)
                let sentinelPointer = UnsafeMutableRawPointer(tailPointer + headPointer.pointee.memorySentinelOffset)
                    .assumingMemoryBound(to: MemorySentinel.self)

                let iovecBufferPointer = UnsafeMutableBufferPointer(
                    start: iovecPointer,
                    count: headPointer.pointee.iovectorCount
                )
                let ownersBufferPointer = UnsafeMutableBufferPointer(
                    start: ownersPointer,
                    count: headPointer.pointee.iovectorCount
                )
                return try body(iovecBufferPointer, ownersBufferPointer, sentinelPointer)
            }
        }
    }
}

extension Int {
    fileprivate mutating func roundUpToAlignment<Type>(for: Type.Type) {
        // Alignment is always positive, we can use unchecked subtraction here.
        let alignmentGuide = MemoryLayout<Type>.alignment &- 1

        // But we can't use unchecked addition.
        self = (self + alignmentGuide) & (~alignmentGuide)
    }
}

struct PooledMsgBuffer: PoolElement {

    private typealias MemorySentinel = UInt32
    private static let sentinelValue = MemorySentinel(0xdead_beef)

    private struct PooledMsgBufferHead {
        let count: Int
        let spaceForMsgHdrs: Int
        let spaceForAddresses: Int
        let spaceForControlData: Int

        init(count: Int) {
            var spaceForMsgHdrs = MemoryLayout<MMsgHdr>.stride * count
            spaceForMsgHdrs.roundUpToAlignment(for: sockaddr_storage.self)

            var spaceForAddress = MemoryLayout<sockaddr_storage>.stride * count
            spaceForAddress.roundUpToAlignment(for: MemorySentinel.self)

            var spaceForControlData = (UnsafeControlMessageStorage.bytesPerMessage * count)
            spaceForControlData.roundUpToAlignment(for: cmsghdr.self)

            self.count = count
            self.spaceForMsgHdrs = spaceForMsgHdrs
            self.spaceForAddresses = spaceForAddress
            self.spaceForControlData = spaceForControlData
        }

        var totalByteCount: Int {
            self.spaceForMsgHdrs + self.spaceForAddresses + self.spaceForControlData + MemoryLayout<MemorySentinel>.size
        }

        var msgHdrsOffset: Int {
            0
        }

        var addressesOffset: Int {
            self.spaceForMsgHdrs
        }

        var controlDataOffset: Int {
            self.spaceForMsgHdrs + self.spaceForAddresses
        }

        var memorySentinelOffset: Int {
            self.spaceForMsgHdrs + self.spaceForAddresses + self.spaceForControlData
        }
    }

    private class BackingStorage: ManagedBuffer<PooledMsgBufferHead, UInt8> {
        static func create(count: Int) -> Self {
            let head = PooledMsgBufferHead(count: count)

            let baseStorage = Self.create(minimumCapacity: head.totalByteCount) { _ in
                head
            }

            // Intentionally using a force cast here to avoid a miss compiliation in 5.10.
            // This is as fast as an unsafeDownCast since ManagedBuffer is inlined and the optimizer
            // can eliminate the upcast/downcast pair
            let storage = baseStorage as! Self
            storage.withUnsafeMutablePointers { headPointer, tailPointer in
                UnsafeRawPointer(tailPointer + headPointer.pointee.msgHdrsOffset).bindMemory(
                    to: MMsgHdr.self,
                    capacity: count
                )
                UnsafeRawPointer(tailPointer + headPointer.pointee.addressesOffset).bindMemory(
                    to: sockaddr_storage.self,
                    capacity: count
                )
                // space for control message data not needed to be bound
                UnsafeRawPointer(tailPointer + headPointer.pointee.memorySentinelOffset).bindMemory(
                    to: MemorySentinel.self,
                    capacity: 1
                )
            }

            return storage
        }

        func withUnsafeMutableTypedPointers<ReturnType>(
            _ body: (
                UnsafeMutableBufferPointer<MMsgHdr>, UnsafeMutableBufferPointer<sockaddr_storage>,
                UnsafeControlMessageStorage, UnsafeMutablePointer<MemorySentinel>
            ) throws -> ReturnType
        ) rethrows -> ReturnType {
            try self.withUnsafeMutablePointers { headPointer, tailPointer in
                let msgHdrsPointer = UnsafeMutableRawPointer(tailPointer + headPointer.pointee.msgHdrsOffset)
                    .assumingMemoryBound(to: MMsgHdr.self)
                let addressesPointer = UnsafeMutableRawPointer(tailPointer + headPointer.pointee.addressesOffset)
                    .assumingMemoryBound(to: sockaddr_storage.self)
                let controlDataPointer = UnsafeMutableRawBufferPointer(
                    start: tailPointer + headPointer.pointee.controlDataOffset,
                    count: headPointer.pointee.spaceForControlData
                )
                let sentinelPointer = UnsafeMutableRawPointer(tailPointer + headPointer.pointee.memorySentinelOffset)
                    .assumingMemoryBound(to: MemorySentinel.self)

                let msgHdrsBufferPointer = UnsafeMutableBufferPointer(
                    start: msgHdrsPointer,
                    count: headPointer.pointee.count
                )
                let addressesBufferPointer = UnsafeMutableBufferPointer(
                    start: addressesPointer,
                    count: headPointer.pointee.count
                )
                let controlMessageStorage = UnsafeControlMessageStorage.makeNotOwning(
                    bytesPerMessage: UnsafeControlMessageStorage.bytesPerMessage,
                    buffer: controlDataPointer
                )
                return try body(msgHdrsBufferPointer, addressesBufferPointer, controlMessageStorage, sentinelPointer)
            }
        }
    }

    private func validateSentinel() {
        self.storage.withUnsafeMutableTypedPointers { _, _, _, sentinelPointer in
            precondition(sentinelPointer.pointee == Self.sentinelValue, "Detected memory handling error!")
        }
    }

    private var storage: BackingStorage

    init() {
        self.storage = .create(count: Socket.writevLimitIOVectors)
        self.storage.withUnsafeMutableTypedPointers { _, _, _, sentinelPointer in
            sentinelPointer.pointee = Self.sentinelValue
        }
    }

    func evictedFromPool() {
        self.validateSentinel()
    }

    func withUnsafePointers<ReturnValue>(
        _ body: (
            UnsafeMutableBufferPointer<MMsgHdr>, UnsafeMutableBufferPointer<sockaddr_storage>,
            UnsafeControlMessageStorage
        ) throws -> ReturnValue
    ) rethrows -> ReturnValue {
        defer {
            self.validateSentinel()
        }
        return try self.storage.withUnsafeMutableTypedPointers { msgs, addresses, controlMessageStorage, _ in
            try body(msgs, addresses, controlMessageStorage)
        }
    }

    func withUnsafePointersWithStorageManagement<ReturnValue>(
        _ body: (
            UnsafeMutableBufferPointer<MMsgHdr>, UnsafeMutableBufferPointer<sockaddr_storage>,
            UnsafeControlMessageStorage, Unmanaged<AnyObject>
        ) throws -> ReturnValue
    ) rethrows -> ReturnValue {
        let storageRef: Unmanaged<AnyObject> = Unmanaged.passUnretained(self.storage)
        return try self.storage.withUnsafeMutableTypedPointers { msgs, addresses, controlMessageStorage, _ in
            try body(msgs, addresses, controlMessageStorage, storageRef)
        }
    }
}
