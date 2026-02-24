import Sparkle
import Cocoa

/// Standard controller for managing Sparkle updates in Ghostty.
///
/// This controller wraps SPUStandardUpdaterController to provide a simpler interface
/// for managing updates with Ghostty's custom driver and delegate. It handles
/// initialization, starting the updater, and provides the check for updates action.
class UpdateController {
    private(set) var updater: SPUUpdater
    private let userDriver: UpdateDriver
    private var isForceInstalling: Bool = false

    var viewModel: UpdateViewModel {
        userDriver.viewModel
    }

    /// True if we're installing an update.
    var isInstalling: Bool {
        isForceInstalling
    }

    /// Initialize a new update controller.
    init() {
        let hostBundle = Bundle.main
        self.userDriver = UpdateDriver(
            viewModel: .init(),
            hostBundle: hostBundle)
        self.updater = SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: hostBundle,
            userDriver: userDriver,
            delegate: userDriver
        )
    }

    deinit {
        MainActor.assumeIsolated {
            isForceInstalling = false
        }
    }

    /// Start the updater.
    ///
    /// This must be called before the updater can check for updates. If starting fails,
    /// the error will be shown to the user.
    func startUpdater() {
        do {
            try updater.start()
        } catch {
            userDriver.viewModel.state = .error(.init(
                error: error,
                retry: { [weak self] in
                    self?.userDriver.viewModel.state = .idle
                    self?.startUpdater()
                },
                dismiss: { [weak self] in
                    self?.userDriver.viewModel.state = .idle
                }
            ))
        }
    }

    /// Force install the current update. As long as we're in some "update available" state this will
    /// trigger all the steps necessary to complete the update.
    func installUpdate() {
        // Must be in an installable state
        guard viewModel.state.isInstallable else { return }

        // If we're already force installing then do nothing.
        guard !isForceInstalling else { return }

        isForceInstalling = true

        // Confirm the current state immediately, then observe for further changes.
        viewModel.state.confirm()
        observeStateForInstall()
    }

    /// Observe the view model's state using Swift Observation. Each time the state
    /// changes, we either confirm the new state (to keep the install chain going)
    /// or stop if we leave an installable state.
    private func observeStateForInstall() {
        guard isForceInstalling else { return }

        withObservationTracking {
            _ = viewModel.state
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.isForceInstalling else { return }

                guard self.viewModel.state.isInstallable else {
                    self.isForceInstalling = false
                    return
                }

                self.viewModel.state.confirm()
                self.observeStateForInstall()
            }
        }
    }

    /// Check for updates.
    ///
    /// This is typically connected to a menu item action.
    @objc func checkForUpdates() {
        // If we're already idle, then just check for updates immediately.
        if viewModel.state == .idle {
            updater.checkForUpdates()
            return
        }

        // If we're not idle then we need to cancel any prior state.
        isForceInstalling = false
        viewModel.state.cancel()

        // The above will take time to settle, so we delay the check for some time.
        // The 100ms is arbitrary and I'd rather not, but we have to wait more than
        // one loop tick it seems.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.updater.checkForUpdates()
        }
    }

    /// Validate the check for updates menu item.
    ///
    /// - Parameter item: The menu item to validate
    /// - Returns: Whether the menu item should be enabled
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkForUpdates) {
            return updater.canCheckForUpdates
        }
        return true
    }
}
