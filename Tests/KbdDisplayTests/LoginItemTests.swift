import ServiceManagement
import XCTest
@testable import KbdDisplay

final class LoginItemTests: XCTestCase {
    private final class Service: LoginItemService {
        var status = SMAppService.Status.notRegistered
        var needsApproval = false
        func register() throws {
            XCTAssertEqual(status, .notRegistered)
            status = needsApproval ? .requiresApproval : .enabled
        }
        func unregister() throws { status = .notRegistered }
    }

    @MainActor func testBothDirectionsAndExternalChanges() {
        let service = Service()
        let item = LoginItem(service: service)
        XCTAssertFalse(item.isEnabled)
        item.setEnabled(true)
        XCTAssertTrue(item.isEnabled)
        item.setEnabled(false)
        XCTAssertEqual(service.status, .notRegistered)
        XCTAssertFalse(item.isEnabled)
        service.status = .enabled
        item.refresh()
        XCTAssertTrue(item.isEnabled)
    }

    @MainActor func testPendingApprovalOpensSettingsAndReflectsActualStatus() {
        let service = Service()
        service.needsApproval = true
        var opened = 0
        let item = LoginItem(service: service) { opened += 1 }
        item.setEnabled(true)
        XCTAssertEqual(opened, 1)
        XCTAssertFalse(item.isEnabled)
        item.setEnabled(true)
        XCTAssertEqual(opened, 2)
        service.status = .enabled
        item.refresh()
        XCTAssertTrue(item.isEnabled)
    }
}
