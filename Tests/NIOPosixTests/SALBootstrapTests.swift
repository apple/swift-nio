import XCTest
import NIOCore
@testable import NIOPosix
import Atomics

final class SALBootstrapTest: XCTestCase { //, SALTest {
    /* var group: MultiThreadedEventLoopGroup!
    var kernelToUserBox: LockedBox<KernelToUser>!
    var userToKernelBox: LockedBox<UserToKernel>!
    var wakeups: LockedBox<()>!

    override func setUp() {
        self.setUpSAL()
    }

    override func tearDown() {
        self.tearDownSAL()
    }

    func testPipeInvalidHandle() throws {
        let sock = socket(AF_LOCAL, SOCK_STREAM, 0)
        // close(sock)

        // There is only one loop in this group
        let eventLoop = self.group.next()
        let bootstrap = NIOPipeBootstrap(group: self.group)

        try eventLoop.runSAL(syscallAssertions: {
            try self.assertRegister { selectable, event, Registration in
                //XCTAssertEqual([.reset], event)
                //print("{sele}")
                return true
            }
            try self.assertDeregister { selectable in
                return true
            }
            try self.assertRegister { selectable, event, Registration in
                //XCTAssertEqual([.reset], event)
                //print("{sele}")
                return true
            }
            try self.assertDeregister { selectable in
                return true
            }
            try self.assertRegister { selectable, event, Registration in
                //XCTAssertEqual([.reset], event)
                //print("{sele}")
                return true
            }
            try self.assertDeregister { selectable in
                return true
            }
        }) {
            let channelFuture = bootstrap.takingOwnershipOfDescriptor(inputOutput: sock)
            let channel = try channelFuture.wait()
        }
    } */

    func testReleaseFileHandleOnOwningFailure() {
        let sock = socket(AF_LOCAL, SOCK_STREAM, 0)
        defer {
            close(sock)
        }
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try! elg.syncShutdownGracefully()
        }

        let bootstrap = NIOPipeBootstrap(validatingGroup: elg, hooks: NIOPipeBootstrapHooksChannelFail())
            XCTAssertNotNil(bootstrap)

        let channelFuture = bootstrap?.takingOwnershipOfDescriptor(inputOutput: sock)
        XCTAssertThrowsError(try channelFuture?.wait())
    }
}


struct NIOPipeBootstrapHooksChannelFail: NIOPipeBootstrapHooks {
    func makePipeChannel(eventLoop: NIOPosix.SelectableEventLoop, inputPipe: NIOCore.NIOFileHandle?, outputPipe: NIOCore.NIOFileHandle?) throws -> NIOPosix.PipeChannel {
        throw IOError(errnoCode: EBADF, reason: "testing")
    }
}
