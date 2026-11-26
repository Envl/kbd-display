import AppKit
import Combine
import ServiceManagement

protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

@MainActor
final class LoginItem: ObservableObject {
    static let title = "Open at Login"

    @Published private(set) var isEnabled: Bool
    private let service: LoginItemService
    private let openSettings: () -> Void

    init(service: LoginItemService = SMAppService.mainApp,
         openSettings: @escaping () -> Void = SMAppService.openSystemSettingsLoginItems) {
        self.service = service
        self.openSettings = openSettings
        isEnabled = service.status == .enabled
    }

    func refresh() {
        let enabled = service.status == .enabled
        if isEnabled != enabled { isEnabled = enabled }
    }

    func setEnabled(_ enabled: Bool) {
        defer { refresh() }
        let status = service.status
        guard enabled != (status == .enabled) else { return }
        do {
            if enabled {
                if status != .requiresApproval { try service.register() }
                if service.status == .requiresApproval { openSettings() }
            } else {
                try service.unregister()
            }
        } catch {
            if enabled && service.status == .requiresApproval {
                openSettings()
            } else {
                NSApp.presentError(error)
            }
        }
    }
}
