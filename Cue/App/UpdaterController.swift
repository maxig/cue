import Combine
import Sparkle

/// Owns Sparkle for the lifetime of the app and exposes just enough state for
/// Cue's SwiftUI and AppKit update buttons.
@MainActor
final class UpdaterController: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    private let standardController: SPUStandardUpdaterController

    init() {
        standardController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        standardController.updater
            .publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        standardController.checkForUpdates(nil)
    }
}
