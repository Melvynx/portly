import Sparkle

/// Owns Sparkle for the whole application lifetime.
///
/// The feed and EdDSA public key live in Info.plist so release builds can be
/// generated without putting update-signing secrets in the repository.
final class PortlyUpdater {
    static let shared = PortlyUpdater()

    let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
