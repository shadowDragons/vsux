import AppKit
import Combine
import Sparkle

/// Sparkle owns downloading, signature verification, delta fallback and installation.
/// Source builds without a release key never start an updater or make network requests.
@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var isConfigured = false
    @Published var automaticallyChecksForUpdates = false {
        didSet {
            guard oldValue != automaticallyChecksForUpdates else { return }
            controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []
    private var startupError: Error?
    private var started = false

    static func hasConfiguration(_ info: [String: Any]) -> Bool {
        guard let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32 else { return false }
        return true
    }

    func start() {
        guard !started else { return }
        started = true
        guard Self.hasConfiguration(Bundle.main.infoDictionary ?? [:]) else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        do {
            try controller.updater.start()
            isConfigured = true
            canCheckForUpdates = controller.updater.canCheckForUpdates
            automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
            observations = [
                controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
                    let value = updater.canCheckForUpdates
                    Task { @MainActor in self?.canCheckForUpdates = value }
                },
                controller.updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] updater, _ in
                    let value = updater.automaticallyChecksForUpdates
                    Task { @MainActor in self?.automaticallyChecksForUpdates = value }
                }
            ]
        } catch {
            startupError = error
        }
    }

    @objc func checkForUpdates(_ sender: Any? = nil) {
        start()
        if let startupError {
            NSAlert(error: startupError).runModal()
        } else if let controller, isConfigured {
            guard canCheckForUpdates else { return }
            controller.checkForUpdates(sender)
        } else {
            let alert = NSAlert()
            alert.messageText = L("此构建未启用应用内更新")
            alert.informativeText = L("请安装配置了更新签名的正式版本；从源码构建的版本可重新构建升级。")
            alert.addButton(withTitle: L("好"))
            alert.runModal()
        }
    }
}
