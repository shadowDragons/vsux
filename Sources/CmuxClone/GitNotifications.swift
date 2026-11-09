import Foundation
import SwiftUI

enum GitNoticeSeverity {
    case error, warning
    var symbol: String { self == .error ? "xmark.circle" : "exclamationmark.triangle" }
    var color: Color { self == .error ? .red : .orange }
    var toastDuration: TimeInterval { self == .error ? 15 : 12 }
}

enum GitNoticeKind: String {
    case operation, refresh, scan, fetch
    var title: String {
        switch self {
        case .operation: return L("Git 操作失败")
        case .refresh: return L("刷新 Git 状态失败")
        case .scan: return L("扫描 Git 仓库失败")
        case .fetch: return L("获取远程状态失败，保留上次结果")
        }
    }
}

struct GitNotice: Identifiable {
    let id: UUID
    let workspaceID: UUID?
    let repositoryURL: URL
    let kind: GitNoticeKind
    let severity: GitNoticeSeverity
    var detail: String
    var occurrences: Int
    var updatedAt: Date
    var canShowOutput: Bool
    var summary: String {
        detail.split(whereSeparator: \.isNewline).first.map(String.init) ?? kind.title
    }
    var source: String { "Git · " + repositoryURL.lastPathComponent }
}

/// Window-owned, in-memory notifications. Hiding a toast and clearing a record
/// are separate operations; periodic background failures never reopen a toast.
@MainActor
final class GitNotificationStore: ObservableObject {
    @Published private(set) var notices: [GitNotice] = []
    @Published private(set) var toastIDs: [UUID] = []
    @Published var isCenterVisible = false
    @Published private(set) var selectedNoticeID: UUID?
    private var remaining: [UUID: TimeInterval] = [:]
    private var protectedToasts: Set<UUID> = []
    private var dismissedBackgroundKeys: Set<String> = []
    private let capacity = 100

    var errorCount: Int { notices.filter { $0.severity == .error }.count }
    var warningCount: Int { notices.filter { $0.severity == .warning }.count }
    var toasts: [GitNotice] { toastIDs.compactMap { id in notices.first { $0.id == id } } }

    private func key(_ repository: URL, _ workspaceID: UUID?, _ kind: GitNoticeKind) -> String {
        (workspaceID?.uuidString ?? "") + ":" + repository.standardizedFileURL.path + ":" + kind.rawValue
    }

    func post(detail: String, repository: URL, workspaceID: UUID?, kind: GitNoticeKind,
              severity: GitNoticeSeverity = .error, silent: Bool = false, canShowOutput: Bool = true) {
        let backgroundKey = key(repository, workspaceID, kind)
        if silent && dismissedBackgroundKeys.contains(backgroundKey) { return }
        // A background Fetch has a stable repository key even if its network error changes.
        let existing = notices.firstIndex {
            $0.workspaceID == workspaceID && $0.repositoryURL.standardizedFileURL.path == repository.standardizedFileURL.path
                && $0.kind == kind && $0.severity == severity && (silent || $0.detail == detail)
        }
        let notice: GitNotice
        if let index = existing {
            var updated = notices.remove(at: index)
            updated.detail = detail; updated.occurrences += 1; updated.updatedAt = Date()
            updated.canShowOutput = canShowOutput
            notice = updated
        } else {
            notice = GitNotice(id: UUID(), workspaceID: workspaceID, repositoryURL: repository, kind: kind,
                severity: severity, detail: detail, occurrences: 1, updatedAt: Date(), canShowOutput: canShowOutput)
        }
        notices.insert(notice, at: 0)
        if !silent && !isCenterVisible {
            hideToast(notice.id)
            toastIDs.append(notice.id)
            remaining[notice.id] = severity.toastDuration
            while toastIDs.count > 3 { hideToast(toastIDs[0]) }
        }
        while notices.count > capacity {
            let removed = notices.removeLast()
            hideToast(removed.id)
        }
    }

    func hideToast(_ id: UUID) {
        toastIDs.removeAll { $0 == id }; remaining[id] = nil; protectedToasts.remove(id)
    }
    func protectToast(_ id: UUID, _ protect: Bool) {
        if protect { protectedToasts.insert(id) } else { protectedToasts.remove(id) }
    }
    func advanceToasts(by elapsed: TimeInterval, appIsActive: Bool) {
        guard appIsActive else { return }
        for id in toastIDs where !protectedToasts.contains(id) {
            remaining[id, default: 0] -= max(0, elapsed)
            if remaining[id, default: 0] <= 0 { hideToast(id) }
        }
    }
    func showCenter(select id: UUID? = nil) {
        selectedNoticeID = id; isCenterVisible = true
        for id in toastIDs { hideToast(id) }
    }
    func toggleCenter() {
        if isCenterVisible { isCenterVisible = false } else { showCenter() }
    }
    func dismiss(_ id: UUID) {
        if let notice = notices.first(where: { $0.id == id }), notice.kind == .fetch {
            dismissedBackgroundKeys.insert(key(notice.repositoryURL, notice.workspaceID, notice.kind))
        }
        notices.removeAll { $0.id == id }; hideToast(id)
    }
    func clearAll() { for id in notices.map(\.id) { dismiss(id) } }
    func resolveBackgroundFetch(repository: URL, workspaceID: UUID?) {
        dismissedBackgroundKeys.remove(key(repository, workspaceID, .fetch))
        for notice in notices where notice.kind == .fetch && notice.workspaceID == workspaceID
            && notice.repositoryURL.standardizedFileURL.path == repository.standardizedFileURL.path {
            notices.removeAll { $0.id == notice.id }; hideToast(notice.id)
        }
    }
}
