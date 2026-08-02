import Foundation
@testable import PortlyApp
import XCTest

final class RuntimeSafetyTests: XCTestCase {
    func testRawWaitStatusIsDecoded() {
        XCTAssertEqual(ProcessExitStatus.normalize(42 << 8), 42)
        XCTAssertEqual(ProcessExitStatus.normalize(1 << 8), 1)
        XCTAssertEqual(ProcessExitStatus.normalize(255 << 8), 255)
    }

    func testDecodedExitAndSignalValuesArePreserved() {
        XCTAssertEqual(ProcessExitStatus.normalize(42), 42)
        XCTAssertEqual(ProcessExitStatus.normalize(15), 15)
        XCTAssertNil(ProcessExitStatus.normalize(nil))
    }

    func testBundleServicesRequireAnApplicationBundle() {
        XCTAssertTrue(AppBundleRuntime.isApplicationBundle(
            bundleURL: URL(fileURLWithPath: "/tmp/Portly.app"),
            bundleIdentifier: "dev.portly.app"
        ))
        XCTAssertFalse(AppBundleRuntime.isApplicationBundle(
            bundleURL: URL(fileURLWithPath: "/tmp/swift-build/release"),
            bundleIdentifier: "dev.portly.app"
        ))
        XCTAssertFalse(AppBundleRuntime.isApplicationBundle(
            bundleURL: URL(fileURLWithPath: "/tmp/Portly.app"),
            bundleIdentifier: nil
        ))
    }
}
