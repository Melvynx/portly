import Sparkle

/// Owns Sparkle for the whole application lifetime.
///
/// The feed and EdDSA public key live in Info.plist so release builds can be
/// generated without putting update-signing secrets in the repository.
final class PortlyUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = PortlyUpdater()

    private(set) var controller: SPUStandardUpdaterController?

    private override init() {
        super.init()
        guard AppBundleRuntime.isApplicationBundle(
            bundleURL: Bundle.main.bundleURL,
            bundleIdentifier: Bundle.main.bundleIdentifier
        ) else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        Supervisor.shared.prepareForUpdaterRelaunch()
    }
}
