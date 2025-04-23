//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// How many file descriptors to open when performing I/O operations.
enum IOStrategy: Hashable, Sendable {
    // platformDefault is reified into one of the concrete options below:
    case sequential
    case parallel(_ maxDescriptors: Int)

    // These selections are relatively arbitrary but the rationale is as follows:
    //
    // - Never exceed the default OS limits even if 4 such operations were happening at once.
    // - Sufficient to enable significant speed up from parallelism
    // - Not wasting effort by pushing contention to the underlying storage device. Further we
    //   assume an SSD or similar underlying storage tech. Users on spinning rust need to account
    //   for that themselves anyway.
    //
    // That said, empirical testing for this has not been performed, suggestions welcome.
    //
    // Note: The directory scan is modelled after a copy strategy needing two handles: during the
    // creation of the destination directory we hold the handle while copying attributes. A much
    // more complex internal state machine could allow doing two of these if desired. This may not
    // result in a faster copy though so things are left simple.
    internal static func determinePlatformDefault() -> Self {
        #if os(macOS) || os(Linux) || os(Windows)
        // Eight file descriptors allow for four concurrent file copies/directory scans. Avoiding
        // storage system contention is of utmost importance.
        //
        // Testing was performed on an SSD, while copying objects (a dense directory of small files
        // and subdirectories of similar shape) to the same volume, totalling 12GB. Results showed
        // improvements in elapsed time for (expected) increases in CPU time up to parallel(8).
        // Beyond this, the increases in CPU led to only moderate gains.
        //
        // Anyone tuning this is encouraged to cover worst case scenarios.
        return .parallel(8)
        #elseif (canImport(Darwin) && !os(macOS)) || os(Android)
        // Reduced maximum descriptors in embedded world. This is chosen based on biasing towards
        // safety, not empirical testing.
        return .parallel(4)
        #else
        // Safety first. If we do not know what system we run on, we keep it simple.
        return .sequential
        #endif
    }
}

/// How to perform copies. Currently only relevant to directory level copies when using
/// ``FileSystemProtocol/copyItem(at:to:strategy:shouldProceedAfterError:shouldCopyItem:)`` or other
/// overloads that use the default behaviour.
public struct CopyStrategy: Hashable, Sendable {
    internal let wrapped: IOStrategy
    private init(_ strategy: IOStrategy) {
        switch strategy {
        case .sequential:
            self.wrapped = .sequential
        case let .parallel(maxDescriptors):
            self.wrapped = .parallel(maxDescriptors)
        }
    }

    // A copy fundamentally can't work without two descriptors unless you copy everything into
    // memory which is infeasible/inefficient for large copies.
    private static let minDescriptorsAllowed = 2

    /// Operate in whatever manner is deemed a reasonable default for the platform. This will limit
    /// the maximum file descriptors usage based on reasonable defaults.
    ///
    /// Current assumptions (which are subject to change):
    /// - Only one copy operation would be performed at once
    /// - The copy operation is not intended to be the primary activity on the device
    public static let platformDefault: Self = Self(IOStrategy.determinePlatformDefault())

    /// The copy is done asynchronously, but only one operation will occur at a time. This is the
    /// only way to guarantee only one callback to the `shouldCopyItem` will happen at a time.
    public static let sequential: Self = Self(.sequential)

    /// Allow multiple I/O operations to run concurrently, including file copies/directory creation
    /// and scanning.
    ///
    /// - Parameter maxDescriptors: a conservative limit on the number of concurrently open file
    ///     descriptors involved in the copy. This number must be >= 2 though, if you are using a
    ///     value that low you should use ``sequential``
    ///
    /// - Throws: ``FileSystemError/Code-swift.struct/invalidArgument`` if `maxDescriptors` is less
    ///     than 2.
    ///
    public static func parallel(maxDescriptors: Int) throws -> Self {
        guard maxDescriptors >= Self.minDescriptorsAllowed else {
            // 2 is not quite the same as sequential, you could have two concurrent directory
            // listings for example less than 2 and you can't actually do a _copy_ though so it's
            // non-sensical.
            throw FileSystemError(
                code: .invalidArgument,
                message: "Can't do a copy operation without at least 2 file descriptors '\(maxDescriptors)' is illegal",
                cause: nil,
                location: .here()
            )
        }
        return .init(.parallel(maxDescriptors))
    }
}

extension CopyStrategy: CustomStringConvertible {
    public var description: String {
        switch self.wrapped {
        case .sequential:
            return "sequential"
        case let .parallel(maxDescriptors):
            return "parallel with max \(maxDescriptors) descriptors"
        }
    }
}

/// How to perform file deletions. Currently only relevant to directory level deletions when using
/// ``FileSystemProtocol/removeItem(at:strategy:recursively:)`` or other overloads that use the
/// default behaviour.
public struct RemovalStrategy: Hashable, Sendable {
    internal let wrapped: IOStrategy
    private init(_ strategy: IOStrategy) {
        switch strategy {
        case .sequential:
            self.wrapped = .sequential
        case let .parallel(maxDescriptors):
            self.wrapped = .parallel(maxDescriptors)
        }
    }

    // A deletion requires no file descriptors. We only consume a file descriptor while scanning the
    // contents of a directory, so the minimum is 1.
    private static let minRequiredDescriptors = 1

    /// Operate in whatever manner is deemed a reasonable default for the platform. This will limit
    /// the maximum file descriptors usage based on reasonable defaults.
    ///
    /// Current assumptions (which are subject to change):
    /// - Only one delete operation would be performed at once
    /// - The delete operation is not intended to be the primary activity on the device
    public static let platformDefault: Self = Self(IOStrategy.determinePlatformDefault())

    /// Traversal of directories and removal of files will be done sequentially without any
    /// parallelization.
    public static let sequential: Self = Self(.sequential)

    /// Allow for one or more directory scans to run at the same time. Removal of files will happen
    /// on asynchronous tasks in parallel.
    ///
    /// Setting `maxDescriptors` to 1, will limit the speed of directory discovery. Deletion of
    /// files within that directory will run in parallel, but discovery of subdirectories will be
    /// limited to one at a time.
    public static func parallel(maxDescriptors: Int) throws -> Self {
        guard maxDescriptors >= Self.minRequiredDescriptors else {
            throw FileSystemError(
                code: .invalidArgument,
                message:
                    "Can't do a remove operation without at least one file descriptor '\(maxDescriptors)' is illegal",
                cause: nil,
                location: .here()
            )
        }
        return .init(.parallel(maxDescriptors))
    }
}

extension RemovalStrategy: CustomStringConvertible {
    public var description: String {
        switch self.wrapped {
        case .sequential:
            return "sequential"
        case let .parallel(maxDescriptors):
            return "parallel with max \(maxDescriptors) descriptors"
        }
    }
}
