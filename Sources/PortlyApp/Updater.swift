import Sparkle

/// Owns Sparkle for the whole application lifetime.
///
/// The feed and EdDSA public key live in Info.plist so release builds can be
/// generated without putting update-signing secrets in the repository.
final class PortlyUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = PortlyUpdater()

    private(set) lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    private override init() {
        super.init()
        _ = controller
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        Supervisor.shared.prepareForUpdaterRelaunch()
    }
}
