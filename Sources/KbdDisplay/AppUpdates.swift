import AppKit
import Combine
import Sparkle

final class AppUpdates: NSObject, ObservableObject {
    @Published private(set) var readyVersion: String?
    private var install: (() -> Void)?
    private var controller: SPUStandardUpdaterController?

    @MainActor func start() {
        guard controller == nil,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return }
        let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        controller = updater
        updater.startUpdater()
    }

    func restartToUpdate() { install?() }

    func stage(version: String, install: @escaping () -> Void) {
        self.install = install
        readyVersion = version
    }

    func clear() {
        install = nil
        readyVersion = nil
    }
}

extension AppUpdates: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock handler: @escaping () -> Void) -> Bool {
        stage(version: item.displayVersionString, install: handler)
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { clear() }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        clear()
    }
}
