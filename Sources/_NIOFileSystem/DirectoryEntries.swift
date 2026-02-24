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

import CNIODarwin
import CNIOLinux
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import SystemPackage

/// An `AsyncSequence` of entries in a directory.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct DirectoryEntries: AsyncSequence, Sendable {
    public typealias AsyncIterator = DirectoryIterator
    public typealias Element = DirectoryEntry

    /// The sequence.
    private let batchedSequence: Batched

    /// Creates a new ``DirectoryEntries`` sequence.
    internal init(handle: SystemFileHandle, recursive: Bool) {
        self.batchedSequence = Batched(handle: handle, recursive: recursive)
    }

    /// Creates a ``DirectoryEntries`` sequence by wrapping an `AsyncSequence` of _batches_ of
    /// directory entries.
    @preconcurrency
    public init<S: AsyncSequence & Sendable>(wrapping sequence: S)
    where S.Element == Batched.Element, S.AsyncIterator: _NIOFileSystemSendableMetatype {
        self.batchedSequence = Batched(wrapping: sequence)
    }

    public func makeAsyncIterator() -> DirectoryIterator {
        DirectoryIterator(iterator: self.batchedSequence.makeAsyncIterator())
    }

    /// Returns a sequence of directory entry batches.
    ///
    /// The batched sequence has its element type as `Array<DirectoryEntry>` rather
    /// than `DirectoryEntry`. This can enable better performance by reducing the number of
    /// executor hops.
    public func batched() -> Batched {
        self.batchedSequence
    }

    /// An `AsyncIteratorProtocol` of `DirectoryEntry`.
    public struct DirectoryIterator: AsyncIteratorProtocol {
        /// The batched iterator to consume from.
        private var iterator: Batched.AsyncIterator
        /// A slice of the current batch being iterated.
        private var currentBatch: ArraySlice<DirectoryEntry>

        init(iterator: Batched.AsyncIterator) {
            self.iterator = iterator
            self.currentBatch = []
        }

        public mutating func next() async throws -> DirectoryEntry? {
            if self.currentBatch.isEmpty {
                let batch = try await self.iterator.next()
                self.currentBatch = (batch ?? [])[...]
            }

            return self.currentBatch.popFirst()
        }
    }
}

@available(*, unavailable)
extension DirectoryEntries.AsyncIterator: Sendable {}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension DirectoryEntries {
    /// An `AsyncSequence` of batches of directory entries.
    ///
    /// The ``Batched`` sequence uses `Array<DirectoryEntry>` as its element type rather
    /// than `DirectoryEntry`. This can enable better performance by reducing the number of
    /// executor hops at the cost of ease-of-use.
    public struct Batched: AsyncSequence, Sendable {
        public typealias AsyncIterator = BatchedIterator
        public typealias Element = [DirectoryEntry]

        private let stream: BufferedOrAnyStream<[DirectoryEntry], DirectoryEntryProducer>

        /// Creates a ``DirectoryEntries/Batched`` sequence by wrapping an `AsyncSequence`
        /// of directory entry batches.
        @preconcurrency
        public init<S: AsyncSequence & Sendable>(wrapping sequence: S)
        where S.Element == Element, S.AsyncIterator: _NIOFileSystemSendableMetatype {
            self.stream = BufferedOrAnyStream<[DirectoryEntry], DirectoryEntryProducer>(wrapping: sequence)
        }

        fileprivate init(handle: SystemFileHandle, recursive: Bool) {
            // Expanding the batches yields watermarks of 256 and 512 directory entries.
            let stream = NIOThrowingAsyncSequenceProducer.makeBatchedDirectoryEntryStream(
                handle: handle,
                recursive: recursive,
                entriesPerBatch: 64,
                lowWatermark: 4,
                highWatermark: 8
            )

            self.stream = BufferedOrAnyStream(wrapping: stream)
        }

        public func makeAsyncIterator() -> BatchedIterator {
            BatchedIterator(wrapping: self.stream.makeAsyncIterator())
        }

        /// An `AsyncIteratorProtocol` of `Array<DirectoryEntry>`.
        public struct BatchedIterator: AsyncIteratorProtocol {
            private var iterator: BufferedOrAnyStream<[DirectoryEntry], DirectoryEntryProducer>.AsyncIterator

            fileprivate init(
                wrapping iterator: BufferedOrAnyStream<[DirectoryEntry], DirectoryEntryProducer>.AsyncIterator
            ) {
                self.iterator = iterator
            }

            public mutating func next() async throws -> [DirectoryEntry]? {
                try await self.iterator.next()
            }
        }
    }
}

@available(*, unavailable)
extension DirectoryEntries.Batched.AsyncIterator: Sendable {}

// MARK: - Internal

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension NIOThrowingAsyncSequenceProducer
where
    Element == [DirectoryEntry],
    Failure == (any Error),
    Strategy == NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark,
    Delegate == DirectoryEntryProducer
{
    fileprivate static func makeBatchedDirectoryEntryStream(
        handle: SystemFileHandle,
        recursive: Bool,
        entriesPerBatch: Int,
        lowWatermark: Int,
        highWatermark: Int
    ) -> NIOThrowingAsyncSequenceProducer<
        [DirectoryEntry], any Error, NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark,
        DirectoryEntryProducer
    > {
        let producer = DirectoryEntryProducer(
            handle: handle,
            recursive: recursive,
            entriesPerBatch: entriesPerBatch
        )

        let nioThrowingAsyncSequence = NIOThrowingAsyncSequenceProducer.makeSequence(
            elementType: [DirectoryEntry].self,
            backPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark(
                lowWatermark: lowWatermark,
                highWatermark: highWatermark
            ),
            finishOnDeinit: false,
            delegate: producer
        )

        producer.setSequenceProducerSource(nioThrowingAsyncSequence.source)

        return nioThrowingAsyncSequence.sequence
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
private typealias DirectoryEntrySequenceProducer = NIOThrowingAsyncSequenceProducer<
    [DirectoryEntry], Error, NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark, DirectoryEntryProducer
>

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
private final class DirectoryEntryProducer: NIOAsyncSequenceProducerDelegate {
    let state: NIOLockedValueBox<DirectoryEnumerator>
    let entriesPerBatch: Int

    init(handle: SystemFileHandle, recursive: Bool, entriesPerBatch: Int) {
        let state = DirectoryEnumerator(handle: handle, recursive: recursive)
        self.state = NIOLockedValueBox(state)
        self.entriesPerBatch = entriesPerBatch
    }

    func didTerminate() {
        guard let threadPool = self.state.withLockedValue({ $0.threadPoolForClosing() }) else {
            return
        }

        threadPool.submit { _ in  // always run, even if cancelled
            self.state.withLockedValue { state in
                state.closeIfNecessary()
            }
        }
    }

    /// sets the source within the producer state
    func setSequenceProducerSource(_ sequenceProducerSource: DirectoryEntrySequenceProducer.Source) {
        self.state.withLockedValue { state in
            switch state.state {
            case .idle:
                state.sequenceProducerSource = sequenceProducerSource
            case .done:
                sequenceProducerSource.finish()
            case .open, .openPausedProducing:
                fatalError()
            case .modifying:
                fatalError()
            }
        }
    }

    func clearSource() {
        self.state.withLockedValue { state in
            state.sequenceProducerSource = nil
        }
    }

    /// The 'entry point' for producing elements.
    ///
    /// Calling this function will start producing directory entries asynchronously by dispatching
    /// work to the IO executor and feeding the result back to the stream source. On yielding to the
    /// source it will either produce more or be scheduled to produce more. Stopping production
    /// is signalled via the stream's 'onTermination' handler.
    func produceMore() {
        let threadPool = self.state.withLockedValue { state in
            state.produceMore()
        }

        // No thread pool means we're done.
        guard let threadPool = threadPool else { return }

        threadPool.submit {
            let result: Result<[DirectoryEntry], Error>
            switch $0 {
            case .active:
                result = Result { try self.nextBatch() }
            case .cancelled:
                result = .failure(CancellationError())
            }
            self.onNextBatchResult(result)
        }
    }

    func pauseProducing() {
        self.state.withLockedValue { state in
            state.pauseProducing()
        }
    }

    private func nextBatch() throws -> [DirectoryEntry] {
        try self.state.withLockedValue { state in
            try state.next(self.entriesPerBatch)
        }
    }

    private func onNextBatchResult(_ result: Result<[DirectoryEntry], Error>) {
        switch result {
        case let .success(entries):
            self.onNextBatch(entries)
        case let .failure(error):
            // Failed to read more entries: close and notify the stream so consumers receive the
            // error.
            self.close()
            let source = self.state.withLockedValue { state in
                state.sequenceProducerSource
            }
            source?.finish(error)
            self.clearSource()
        }
    }

    private func onNextBatch(_ entries: [DirectoryEntry]) {
        let source = self.state.withLockedValue { state in
            state.sequenceProducerSource
        }

        guard let source else {
            assertionFailure("unexpectedly missing source")
            return
        }

        // No entries were read: this must be the end (as the batch size must be greater than zero).
        if entries.isEmpty {
            source.finish()
            self.clearSource()
            return
        }

        // Reading short means reading EOF. The enumerator closes itself in that case.
        let readEOF = entries.count < self.entriesPerBatch

        // Entries were produced: yield them and maybe produce more.
        let writeResult = source.yield(contentsOf: CollectionOfOne(entries))

        // Exit early if EOF was read; no use in trying to produce more.
        if readEOF {
            source.finish()
            self.clearSource()
            return
        }

        switch writeResult {
        case .produceMore:
            self.produceMore()
        case .stopProducing:
            self.pauseProducing()
        case .dropped:
            // The source is finished; mark ourselves as done.
            self.close()
        }
    }

    private func close() {
        guard let threadPool = self.state.withLockedValue({ $0.threadPoolForClosing() }) else {
            return
        }

        threadPool.submit { _ in  // always run, even if cancelled
            self.state.withLockedValue { state in
                state.closeIfNecessary()
            }
        }
    }
}

/// Enumerates a directory in batches.
///
/// Note that this is not a `Sequence` because we allow for errors to be thrown on `next()`.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
private struct DirectoryEnumerator: Sendable {
    internal enum State: @unchecked Sendable {
        case modifying
        case idle(SystemFileHandle.SendableView, recursive: Bool)
        case open(NIOThreadPool, Source, [DirectoryEntry])
        case openPausedProducing(NIOThreadPool, Source, [DirectoryEntry])
        case done
    }

    /// The source of directory entries.
    internal enum Source {
        case readdir(CInterop.DirPointer)
        case fts(CInterop.FTSPointer)
    }

    /// The current state of enumeration.
    internal var state: State

    /// The path to the directory being enumerated.
    private let path: FilePath

    /// The route via which directory entry batches are yielded,
    /// the sourcing end of the `DirectoryEntrySequenceProducer`
    internal var sequenceProducerSource: DirectoryEntrySequenceProducer.Source?

    /// Information about an entry returned by FTS. See 'fts(3)'.
    private enum FTSInfo: Hashable, Sendable {
        case directoryPreOrder
        case directoryCausingCycle
        case ftsDefault
        case directoryUnreadable
        case dotFile
        case directoryPostOrder
        case error
        case regularFile
        case noStatInfoAvailable
        case noStatInfoRequested
        case symbolicLink
        case symbolicLinkToNonExistentTarget

        init?(rawValue: UInt16) {
            switch Int32(rawValue) {
            case FTS_D:
                self = .directoryPreOrder
            case FTS_DC:
                self = .directoryCausingCycle
            case FTS_DEFAULT:
                self = .ftsDefault
            case FTS_DNR:
                self = .directoryUnreadable
            case FTS_DOT:
                self = .dotFile
            case FTS_DP:
                self = .directoryPostOrder
            case FTS_ERR:
                self = .error
            case FTS_F:
                self = .regularFile
            case FTS_NS:
                self = .noStatInfoAvailable
            case FTS_NSOK:
                self = .noStatInfoRequested
            case FTS_SL:
                self = .symbolicLink
            case FTS_SLNONE:
                self = .symbolicLinkToNonExistentTarget
            default:
                return nil
            }
        }
    }

    internal init(handle: SystemFileHandle, recursive: Bool) {
        self.state = .idle(handle.sendableView, recursive: recursive)
        self.path = handle.path
    }

    internal mutating func produceMore() -> NIOThreadPool? {
        switch self.state {
        case let .idle(handle, _):
            return handle.threadPool
        case let .open(threadPool, _, _):
            return threadPool
        case .openPausedProducing(let threadPool, let source, let array):
            self.state = .open(threadPool, source, array)
            return threadPool
        case .done:
            return nil
        case .modifying:
            fatalError()
        }
    }

    internal mutating func pauseProducing() {
        switch self.state {
        case .open(let threadPool, let source, let array):
            self.state = .openPausedProducing(threadPool, source, array)
        case .idle:
            ()  // we won't apply back pressure until something has been read
        case .openPausedProducing, .done:
            ()  // no-op
        case .modifying:
            fatalError()
        }
    }

    internal func threadPoolForClosing() -> NIOThreadPool? {
        switch self.state {
        case .open(let threadPool, _, _), .openPausedProducing(let threadPool, _, _):
            return threadPool
        case .idle, .done:
            // Don't need to close in the idle state: we don't own the handle.
            return nil
        case .modifying:
            fatalError()
        }
    }

    /// Returns the next batch of directory entries.
    internal mutating func next(_ count: Int) throws -> [DirectoryEntry] {
        while true {
            switch self.process(count) {
            case let .yield(result):
                return try result.get()
            case .continue:
                ()
            }
        }
    }

    /// Closes the descriptor, if necessary.
    internal mutating func closeIfNecessary() {
        switch self.state {
        case .idle:
            // We don't own the handle so don't close it.
            self.state = .done

        case .open(_, let mode, _), .openPausedProducing(_, let mode, _):
            self.state = .done
            switch mode {
            case .readdir(let dir):
                _ = Libc.closedir(dir)
            case .fts(let fts):
                _ = Libc.ftsClose(fts)
            }

        case .done:
            ()

        case .modifying:
            fatalError()
        }
    }

    private enum ProcessResult {
        case yield(Result<[DirectoryEntry], FileSystemError>)
        case `continue`
    }

    private mutating func makeReaddirSource(
        _ handle: SystemFileHandle.SendableView
    ) -> Result<Source, FileSystemError> {
        handle._duplicate().mapError { dupError in
            FileSystemError(
                message: "Unable to open directory stream for '\(handle.path)'.",
                wrapping: dupError
            )
        }.flatMap { descriptor in
            // We own the descriptor and cede ownership if 'opendir' succeeds; if it doesn't we need
            // to close it.
            descriptor.opendir().mapError { errno in
                // Close the descriptor on error.
                try? descriptor.close()
                return FileSystemError.fdopendir(errno: errno, path: handle.path, location: .here())
            }
        }.map {
            .readdir($0)
        }
    }

    private mutating func makeFTSSource(
        _ handle: SystemFileHandle.SendableView
    ) -> Result<Source, FileSystemError> {
        Libc.ftsOpen(handle.path, options: [.noChangeDir, .physical]).mapError { errno in
            FileSystemError.open("fts_open", error: errno, path: handle.path, location: .here())
        }.map {
            .fts($0)
        }
    }

    private mutating func processOpenState(
        threadPool: NIOThreadPool,
        dir: CInterop.DirPointer,
        entries: inout [DirectoryEntry],
        count: Int
    ) -> (State, ProcessResult) {
        entries.removeAll(keepingCapacity: true)
        entries.reserveCapacity(count)

        while entries.count < count {
            switch Libc.readdir(dir) {
            case let .success(.some(entry)):
                // Skip "." and ".." (and empty paths)
                if self.isThisOrParentDirectory(entry.pointee) {
                    continue
                }

                let fileType = FileType(direntType: entry.pointee.d_type)
                let name: FilePath.Component
                #if canImport(Darwin)
                // Safe to force unwrap: may be nil if empty, a root, or more than one component.
                // Empty is checked for above, root can't exist within a directory, and directory
                // items must be a single path component.
                name = FilePath.Component(platformString: CNIODarwin_dirent_dname(entry))!
                #else
                name = FilePath.Component(platformString: CNIOLinux_dirent_dname(entry))!
                #endif

                let fullPath = self.path.appending(name)
                // '!' is okay here: the init returns nil if there is an empty path which we know
                // isn't the case as 'self.path' is non-empty.
                entries.append(DirectoryEntry(path: fullPath, type: fileType)!)

            case .success(.none):
                // Nothing we can do on failure so ignore the result.
                _ = Libc.closedir(dir)
                return (.done, .yield(.success(entries)))

            case let .failure(errno):
                // Nothing we can do on failure so ignore the result.
                _ = Libc.closedir(dir)
                let error = FileSystemError.readdir(
                    errno: errno,
                    path: self.path,
                    location: .here()
                )
                return (.done, .yield(.failure(error)))
            }
        }

        // We must have hit our 'count' limit.
        return (.open(threadPool, .readdir(dir), entries), .yield(.success(entries)))
    }

    private mutating func processOpenState(
        threadPool: NIOThreadPool,
        fts: CInterop.FTSPointer,
        entries: inout [DirectoryEntry],
        count: Int
    ) -> (State, ProcessResult) {
        entries.removeAll(keepingCapacity: true)
        entries.reserveCapacity(count)

        while entries.count < count {
            switch Libc.ftsRead(fts) {
            case .success(.some(let entry)):
                let info = FTSInfo(rawValue: entry.pointee.fts_info)
                switch info {
                case .directoryPreOrder:
                    let entry = DirectoryEntry(path: entry.path, type: .directory)!
                    entries.append(entry)

                case .directoryPostOrder:
                    ()  // Don't visit directories twice.

                case .regularFile:
                    let entry = DirectoryEntry(path: entry.path, type: .regular)!
                    entries.append(entry)

                case .symbolicLink, .symbolicLinkToNonExistentTarget:
                    let entry = DirectoryEntry(path: entry.path, type: .symlink)!
                    entries.append(entry)

                case .ftsDefault:
                    // File type is unknown.
                    let entry = DirectoryEntry(path: entry.path, type: .unknown)!
                    entries.append(entry)

                case .error:
                    let errno = Errno(rawValue: entry.pointee.fts_errno)
                    let error = FileSystemError(
                        code: .unknown,
                        message: "Can't read file system tree.",
                        cause: FileSystemError.SystemCallError(systemCall: "fts_read", errno: errno),
                        location: .here()
                    )
                    _ = Libc.ftsClose(fts)
                    return (.done, .yield(.failure(error)))

                case .directoryCausingCycle:
                    ()  // Cycle found, ignore it and continue.
                case .directoryUnreadable:
                    ()  // Can't read directory, ignore it and continue iterating.
                case .dotFile:
                    ()  // Ignore "." and ".."
                case .noStatInfoAvailable:
                    ()  // No stat info available so we can't list the entry, ignore it.
                case .noStatInfoRequested:
                    ()  // Shouldn't happen.

                case nil:
                    ()  // Unknown, ignore.
                }

            case .success(.none):
                // No entries left to iterate.
                _ = Libc.ftsClose(fts)
                return (.done, .yield(.success(entries)))

            case .failure(let errno):
                // Nothing we can do on failure so ignore the result.
                _ = Libc.ftsClose(fts)
                let error = FileSystemError.ftsRead(
                    errno: errno,
                    path: self.path,
                    location: .here()
                )
                return (.done, .yield(.failure(error)))
            }
        }

        // We must have hit our 'count' limit.
        return (.open(threadPool, .fts(fts), entries), .yield(.success(entries)))
    }

    private mutating func process(_ count: Int) -> ProcessResult {
        switch self.state {
        case let .idle(handle, recursive):
            let result: Result<Source, FileSystemError>

            if recursive {
                result = self.makeFTSSource(handle)
            } else {
                result = self.makeReaddirSource(handle)
            }

            switch result {
            case let .success(source):
                self.state = .open(handle.threadPool, source, [])
                return .continue

            case let .failure(error):
                self.state = .done
                return .yield(.failure(error))
            }

        case .open(let threadPool, let mode, var entries):
            self.state = .modifying

            switch mode {
            case .readdir(let dir):
                let (state, result) = self.processOpenState(
                    threadPool: threadPool,
                    dir: dir,
                    entries: &entries,
                    count: count
                )
                self.state = state
                return result

            case .fts(let fts):
                let (state, result) = self.processOpenState(
                    threadPool: threadPool,
                    fts: fts,
                    entries: &entries,
                    count: count
                )
                self.state = state
                return result
            }

        case .openPausedProducing:
            return .yield(.success([]))

        case .done:
            return .yield(.success([]))

        case .modifying:
            fatalError()
        }
    }

    private func isThisOrParentDirectory(_ entry: CInterop.DirEnt) -> Bool {
        let dot = CChar(bitPattern: UInt8(ascii: "."))
        switch (entry.d_name.0, entry.d_name.1, entry.d_name.2) {
        case (0, _, _), (dot, 0, _), (dot, dot, 0):
            return true
        default:
            return false
        }
    }
}

extension UnsafeMutablePointer<CInterop.FTSEnt> {
    fileprivate var path: FilePath {
        FilePath(platformString: self.pointee.fts_path!)
    }
}
