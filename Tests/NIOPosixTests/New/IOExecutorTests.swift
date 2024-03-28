import NIOPosix
import XCTest

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
final class IOExecutorTests: XCTestCase {
    static let executor = IOExecutor.make(name: "Test")

    func testBasicExecutor() async throws {
        await _withTaskExecutor(Self.executor) {
            Self.executor.preconditionOnExecutor()
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    Self.executor.preconditionOnExecutor()
                }
                group.addTask {
                    Self.executor.preconditionOnExecutor()
                }
            }
        }
    }
}
