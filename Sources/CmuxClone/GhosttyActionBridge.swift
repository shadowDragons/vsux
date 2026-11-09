import AppKit
import CGhostty

/// Ghostty can call action_cb on a renderer thread while holding terminal
/// locks. Never wait for the main thread or retain borrowed C payloads here.
final class GhosttyActionBridge: @unchecked Sendable {
    private let lock = NSLock()
    // The lock protects the map; each endpoint's view is main-actor-owned.
    private var targets: [UInt: Endpoint] = [:]

    @MainActor func register(surface: ghostty_surface_t, view: GhosttyTerminalView) {
        let endpoint = Endpoint(view: view)
        lock.lock()
        targets[UInt(bitPattern: surface)] = endpoint
        lock.unlock()
    }

    @MainActor func unregister(surface: ghostty_surface_t) {
        lock.lock()
        targets.removeValue(forKey: UInt(bitPattern: surface))
        lock.unlock()
    }

    func receive(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        // Unsupported renderer events must return without entering MainActor.
        guard let event = Event(action), target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface else { return false }
        // Use the pointer only as an identity key. It may be destroyed before
        // a queued UI update runs, so never dereference it in that update.
        lock.lock()
        let endpoint = targets[UInt(bitPattern: surface)]
        lock.unlock()
        guard let endpoint else { return false }
        if Thread.isMainThread {
            MainActor.assumeIsolated { endpoint.deliver(event) }
        } else {
            DispatchQueue.main.async { [weak endpoint] in endpoint?.deliver(event) }
        }
        return true
    }

    private enum Event: Sendable {
        case title(String), directory(String), openURL(String), startSearch

        init?(_ action: ghostty_action_s) {
            switch action.tag {
            case GHOSTTY_ACTION_SET_TITLE:
                guard let value = action.action.set_title.title else { return nil }
                self = .title(String(cString: value))
            case GHOSTTY_ACTION_PWD:
                guard let value = action.action.pwd.pwd else { return nil }
                self = .directory(String(cString: value))
            case GHOSTTY_ACTION_OPEN_URL:
                guard let value = action.action.open_url.url else { return nil }
                let bytes = Data(bytes: value, count: Int(action.action.open_url.len))
                guard let value = String(data: bytes, encoding: .utf8) else { return nil }
                self = .openURL(value)
            case GHOSTTY_ACTION_START_SEARCH: self = .startSearch
            default: return nil
            }
        }
    }

    @MainActor private final class Endpoint {
        weak var view: GhosttyTerminalView?
        init(view: GhosttyTerminalView) { self.view = view }

        func deliver(_ event: Event) {
            guard let view, view.surface != nil else { return }
            switch event {
            case .title(let title): view.model?.updateTitle(pane: view.paneID, title: title)
            case .directory(let directory): view.directory = directory
            case .openURL(let string):
                if let url = URL(string: string), ["http", "https", "file", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                }
            case .startSearch: break
            }
        }
    }
}
