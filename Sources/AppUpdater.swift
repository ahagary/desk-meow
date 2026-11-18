import AppKit
import Sparkle

/// Sparkle owns signature verification, download, installation and relaunch.
/// Only an explicit user action starts an update check.
final class AppUpdater: NSObject, SPUUpdaterDelegate, NSMenuItemValidation {
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    var onStateChanged: (() -> Void)?
    private var preparingCheck = false
    private var observations: [NSKeyValueObservation] = []
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false,
        updaterDelegate: self, userDriverDelegate: nil)

    var menuTitle: String {
        if preparingCheck { return "正在检查更新…" }
        return "检查更新…"
    }

    func start() {
        // 0.2.0 may have persisted automatic checks. Disable those before Sparkle
        // is initialized so an existing installation also becomes manual-only.
        UserDefaults.standard.set(false, forKey: "SUEnableAutomaticChecks")
        UserDefaults.standard.set(false, forKey: "SUAutomaticallyUpdate")
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
                self?.onStateChanged?()
            }
        ]
        controller.startUpdater()
        onStateChanged?()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard !preparingCheck, controller.updater.canCheckForUpdates else { return }
        NSApp.activate(ignoringOtherApps: true)
        guard let address = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: address) else { return }
        preparingCheck = true
        onStateChanged?()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "HEAD"
        // Before the first public release there is no feed yet. Explain that
        // state without presenting it as "already up to date" or installing anything.
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.preparingCheck = false
                self.onStateChanged?()
                if error != nil {
                    self.showMessage("暂时无法检查更新", detail: "当前版本：\(self.currentVersion)\n请检查网络连接，稍后再试。")
                } else if (response as? HTTPURLResponse)?.statusCode == 404 {
                    self.showMessage("暂无可用的更新信息", detail: "当前版本：\(self.currentVersion)\n正式更新尚未发布，请稍后再检查。现有功能可以继续使用。")
                } else if self.controller.updater.canCheckForUpdates {
                    // Sparkle fetches and validates the signed feed itself. The
                    // preliminary request is never used as trusted update data.
                    self.controller.checkForUpdates(nil)
                }
            }
        }.resume()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates(_:)) {
            return !preparingCheck && controller.updater.canCheckForUpdates
        }
        return true
    }

    private func showMessage(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
