import AppKit
import Sparkle

@MainActor
final class UpdateController: NSObject, SPUUpdaterDelegate, NSMenuItemValidation {
    private let checkpoint: () -> Bool
    private var controller: SPUStandardUpdaterController?
    private var started = false

    init(checkpoint: @escaping () -> Bool) { self.checkpoint = checkpoint; super.init() }

    func start() {
        guard !started, Bundle.main.bundleURL.pathExtension == "app",
              ProcessInfo.processInfo.environment["LUNA_RECOVERY_DIR"] == nil else { return }
        #if DEBUG
        return
        #else
        started = true
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        // Keep all network and updater initialization off the first-window path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let updater = self?.controller?.updater,
                  updater.automaticallyChecksForUpdates, updater.canCheckForUpdates else { return }
            updater.checkForUpdatesInBackground()
        }
        #endif
    }

    @objc func checkForUpdates(_ sender: Any?) { start(); controller?.checkForUpdates(sender) }
    @objc func toggleAutomaticChecks(_ sender: Any?) {
        start()
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates.toggle()
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleAutomaticChecks(_:)) {
            menuItem.state = controller?.updater.automaticallyChecksForUpdates == true ? .on : .off
            return controller != nil
        }
        return controller?.updater.canCheckForUpdates == true
    }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard checkpoint() else {
            throw NSError(domain: "Luna.Updates", code: 1, userInfo: [NSLocalizedDescriptionKey: "Save your notes before installing this update. Luna could not write its recovery copy."])
        }
    }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { _ = checkpoint() }
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { _ = checkpoint() }
    // applicationShouldTerminate also refuses termination if recovery fails.
}
