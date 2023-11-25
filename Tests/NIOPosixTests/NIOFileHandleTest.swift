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

import Dispatch
import NIOPosix
import XCTest

@testable import NIOCore

final class NIOFileHandleTest: XCTestCase {
    func testOpenCloseWorks() throws {
        let pipeFDs = try Self.makePipe()
        let fh1 = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: pipeFDs.0)
        XCTAssertTrue(fh1.isOpen)
        defer {
            XCTAssertTrue(fh1.isOpen)
            XCTAssertNoThrow(try fh1.close())
            XCTAssertFalse(fh1.isOpen)
        }
        let fh2 = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: pipeFDs.1)
        XCTAssertTrue(fh2.isOpen)
        defer {
            XCTAssertTrue(fh2.isOpen)
            XCTAssertNoThrow(try fh2.close())
            XCTAssertFalse(fh2.isOpen)
        }
        XCTAssertTrue(fh1.isOpen)
        XCTAssertTrue(fh2.isOpen)
    }

    func testCloseStorm() throws {
        for _ in 0..<1000 {
            let pipeFDs = try Self.makePipe()
            let fh1 = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: pipeFDs.0)
            let fh2 = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: pipeFDs.1)

            let threads = 32
            let threadReadySems = (0..<threads).map { _ in
                DispatchSemaphore(value: 0)
            }
            let threadGoSems = (0..<threads).map { _ in
                DispatchSemaphore(value: 0)
            }
            let allDoneGroup = DispatchGroup()

            for threadID in 0..<threads {
                DispatchQueue.global().async(group: allDoneGroup) {
                    threadReadySems[threadID].signal()
                    threadGoSems[threadID].wait()

                    do {
                        if threadID % 2 == 0 {
                            try fh1.close()
                        } else {
                            try fh2.close()
                        }
                    } catch let error as IOError where error.errnoCode == EBADF {
                        // expected
                    } catch {
                        XCTFail("unexpected error \(error)")
                    }
                }
            }

            for threadReadySem in threadReadySems {
                threadReadySem.wait()
            }
            for threadGoSem in threadGoSems {
                threadGoSem.signal()
            }
            allDoneGroup.wait()
            XCTAssertFalse(fh1.isOpen)
            XCTAssertFalse(fh2.isOpen)
        }
    }

    func testCloseVsUseRace() throws {
        for _ in 0..<1000 {
            let pipeFDs = try Self.makePipe()
            let fh1 = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: pipeFDs.0)
            let fh2 = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: pipeFDs.1)

            let threads = 32
            let threadReadySems = (0..<threads).map { _ in
                DispatchSemaphore(value: 0)
            }
            let threadGoSems = (0..<threads).map { _ in
                DispatchSemaphore(value: 0)
            }
            let allDoneGroup = DispatchGroup()

            for threadID in 0..<threads {
                DispatchQueue.global().async(group: allDoneGroup) {
                    threadReadySems[threadID].signal()
                    threadGoSems[threadID].wait()

                    do {
                        switch threadID % 4 {
                        case 0:
                            try fh1.close()
                        case 1:
                            try fh2.close()
                        case 2:
                            try fh1.withUnsafeFileDescriptor { fd in
                                precondition(fd >= 0)
                                usleep(.random(in: 0..<10))
                            }
                        case 3:
                            try fh2.withUnsafeFileDescriptor { fd in
                                precondition(fd >= 0)
                                usleep(.random(in: 0..<10))
                            }
                        default:
                            fatalError("impossible")
                        }
                    } catch let error as IOError where error.errnoCode == EBADF || error.errnoCode == EBUSY {
                        // expected
                    } catch {
                        XCTFail("unexpected error \(error)")
                    }
                }
            }

            for threadReadySem in threadReadySems {
                threadReadySem.wait()
            }
            for threadGoSem in threadGoSems {
                threadGoSem.signal()
            }
            allDoneGroup.wait()
            for fh in [fh1, fh2] {
                // They may or may not be closed, depends on races above.
                do {
                    try fh.close()
                } catch let error as IOError where error.errnoCode == EBADF {
                    // expected
                }
            }
            XCTAssertFalse(fh1.isOpen)
            XCTAssertFalse(fh2.isOpen)
        }
    }

    // MARK: - Helpers
    struct POSIXError: Error {
        var what: String
        var errnoCode: CInt
    }

    private static func makePipe() throws -> (CInt, CInt) {
        var pipeFDs: [CInt] = [-1, -1]
        let err = pipeFDs.withUnsafeMutableBufferPointer { pipePtr in
            pipe(pipePtr.baseAddress!)
        }
        guard err == 0 else {
            throw POSIXError(what: "pipe", errnoCode: errno)
        }
        return (pipeFDs[0], pipeFDs[1])
    }
}
