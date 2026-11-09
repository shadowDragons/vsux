import AppKit
import SwiftUI

struct RepositoryActionsMenu: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject var model: SourceControlModel
    let repository: LocalGitSnapshot
    let showDetails: () -> Void
    @State private var branchPicker: GitBranchPickerPurpose?

    private func select() { model.selectRepository(repository.rootURL) }
    private func run(_ operation: LocalGitOperation) {
        Task { await model.perform(operation, in: repository.rootURL) }
    }
    private var hasConflict: Bool { repository.changes.contains(where: \.isConflicted) }
    private var otherBranches: [String] { repository.branches.filter { $0 != repository.branch } }
    private var trackedChanges: [LocalGitChange] { repository.changes.filter { $0.isUnstaged && !$0.isUntracked && !$0.isConflicted } }

    var body: some View {
        let _ = languagePreferences.language
        Menu {
            Button(L("Pull（拉取，快进）")) { run(.pull(rebase: false)) }.disabled(repository.remotes.isEmpty)
            Menu(L("Push（推送）")) { pushButtons(tags: false) }.disabled(repository.remotes.isEmpty || repository.branch == nil)
            Button(L("Clone（克隆）…")) { askCloneRepository(model: model) }
            checkoutMenu
            Menu(L("Fetch（获取）")) {
                Button(L("获取全部远程并清理失效引用")) { run(.fetchAll) }
                Divider()
                ForEach(repository.remotes, id: \.self) { remote in Button(remote) { run(.fetch(remote)) } }
            }.disabled(repository.remotes.isEmpty)
            Divider()
            commitMenu
            changesMenu
            Menu("Pull / Push") {
                Button(L("拉取（仅快进）")) { run(.pull(rebase: false)) }
                Button(L("拉取并变基")) { run(.pull(rebase: true)) }
                Menu(L("推送当前分支 / 设置上游")) { pushButtons(tags: false) }
                Menu(L("推送全部本地标签")) { pushButtons(tags: true) }
            }.disabled(repository.remotes.isEmpty)
            branchMenu
            remoteMenu
            stashMenu
            tagsMenu
            worktreesMenu
            Divider()
            Button(L("查看提交历史")) { select(); showDetails(); Task { await model.showHistory() } }.disabled(repository.head == nil)
            Button(L("显示 Git 输出")) { select(); showDetails(); Task { await model.showGitOutput() } }
            Button(L("刷新")) { select(); Task { await model.refresh() } }
            Button(L("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([repository.rootURL]) }
            Button(L("复制仓库路径")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(repository.rootURL.path, forType: .string)
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 23, height: 25)
        }
        .menuStyle(.borderlessButton).pointingHandCursor().menuIndicator(.hidden).fixedSize()
        .disabled(model.isBusy)
        .help(L("\(repository.rootURL.lastPathComponent) 仓库操作"))
        .accessibilityLabel(L("\(repository.rootURL.lastPathComponent) 仓库操作"))
        .sheet(item: $branchPicker) { purpose in
            GitBranchPicker(model: model, repository: repository, purpose: purpose)
        }
    }

    private func pushButtons(tags: Bool) -> some View {
        ForEach(repository.remotes, id: \.self) { remote in
            Button(remote) { run(.push(remote, tags: tags)) }
        }
    }

    private var checkoutMenu: some View {
        Button(L("Checkout to…（切换到）")) { openBranchPicker(.checkout) }
    }

    private func openBranchPicker(_ purpose: GitBranchPickerPurpose) {
        select()
        branchPicker = purpose
    }

    private var commitMenu: some View {
        Menu(L("Commit（提交）")) {
            Button(L("提交已暂存更改…")) { requestCommit() }
                .disabled(!repository.changes.contains(where: \.isStaged) || hasConflict)
            Button(L("暂存全部并提交…")) { requestCommit(stageAll: true) }
                .disabled(repository.changes.isEmpty || hasConflict)
            Button(L("修改最近一次提交…")) { requestCommit(amend: true) }.disabled(repository.head == nil || hasConflict)
            Divider()
            Button(L("撤销最近一次提交（保留更改）…")) {
                if confirm(title: L("撤销最近一次提交？"), detail: L("当前分支回退一次提交，更改保留在暂存区。已推送的历史也会受到影响。"), action: L("撤销提交")) { run(.undoCommit) }
            }.disabled(repository.head == nil)
        }
    }

    private var changesMenu: some View {
        Menu(L("Changes（更改）")) {
            Button(L("暂存全部更改")) { select(); Task { await model.stage(repository.changes.filter(\.isUnstaged), in: repository.rootURL) } }
                .disabled(!repository.changes.contains(where: \.isUnstaged))
            Button(L("取消全部暂存")) { select(); Task { await model.unstage(repository.changes.filter(\.isStaged), in: repository.rootURL) } }
                .disabled(!repository.changes.contains(where: \.isStaged))
            Divider()
            Button(L("查看工作区差异")) { select(); showDetails(); Task { await model.showRepositoryDiff(staged: false) } }
            Button(L("查看已暂存差异")) { select(); showDetails(); Task { await model.showRepositoryDiff(staged: true) } }
            Divider()
            Button(L("放弃已跟踪文件的未暂存更改…")) {
                if confirm(title: L("放弃 \(trackedChanges.count) 个文件的未暂存更改？"), detail: L("文件会恢复为暂存区版本，尚未暂存的编辑无法通过此应用恢复。"), action: L("放弃更改")) {
                    run(.discardTracked(trackedChanges.map(\.path)))
                }
            }.disabled(trackedChanges.isEmpty)
            Button(L("将未跟踪文件移到废纸篓…")) {
                let files = repository.changes.filter(\.isUntracked)
                if confirm(title: L("将 \(files.count) 个未跟踪文件移到废纸篓？"), detail: L("可在 macOS 废纸篓中恢复。"), action: L("移到废纸篓")) {
                    run(.discardUntracked(files.map(\.path)))
                }
            }.disabled(!repository.changes.contains(where: \.isUntracked))
        }
    }

    private var branchMenu: some View {
        Menu(L("Branch（分支）")) {
            Button(L("Merge…（合并分支）")) { openBranchPicker(.merge) }
                .disabled(repository.branch == nil || repository.isMerging || repository.isRebasing)
            Button(L("Rebase…（变基）")) { openBranchPicker(.rebase) }
                .disabled(repository.branch == nil || repository.isMerging || repository.isRebasing)
            Divider()
            Button(L("新建本地分支…")) { createBranch() }
            Button(L("重命名当前分支…")) {
                if let old = repository.branch, let name = askText(title: L("重命名分支"), value: old), name != old { run(.renameBranch(old, name)) }
            }.disabled(repository.branch == nil)
            Menu(L("删除已合并的本地分支")) {
                ForEach(otherBranches, id: \.self) { branch in
                    Button(branch) {
                        if confirm(title: L("删除本地分支 \(branch)？"), detail: L("Git 会拒绝删除尚未合并的分支。"), action: L("删除分支")) { run(.deleteBranch(branch)) }
                    }
                }
            }.disabled(otherBranches.isEmpty)
            Divider()
            Button(L("中止合并")) { run(.abortMerge) }.disabled(!repository.isMerging)
            Button(L("继续变基")) { run(.continueRebase) }.disabled(!repository.isRebasing || hasConflict)
            Button(L("中止变基")) { run(.abortRebase) }.disabled(!repository.isRebasing)
        }
    }

    private var remoteMenu: some View {
        Menu(L("Remote（远程仓库）")) {
            Button(L("添加远程仓库…")) {
                if let name = askText(title: L("远程仓库名称"), value: "origin"),
                   let url = askText(title: L("远程仓库地址（HTTPS / SSH / 本地路径）"), value: "") { run(.addRemote(name, url)) }
            }
            ForEach(repository.remotes, id: \.self) { remote in
                Menu(remote) {
                    Button(L("查看地址")) {
                        select(); showDetails()
                        Task { if let url = await model.remoteURL(remote, in: repository.rootURL) { model.diffTitle = remote + L(" · 远程地址"); model.diffText = url } }
                    }
                    Button(L("更改地址…")) {
                        if let url = askText(title: L("\(remote) 的新地址"), value: "") { run(.setRemoteURL(remote, url)) }
                    }
                    Button(L("重命名…")) {
                        if let name = askText(title: L("重命名远程仓库"), value: remote), name != remote { run(.renameRemote(remote, name)) }
                    }
                    Button(L("移除…")) {
                        if confirm(title: L("移除远程仓库 \(remote)？"), detail: L("删除本机的远程配置和跟踪引用，不会删除服务器上的仓库。"), action: L("移除")) { run(.removeRemote(remote)) }
                    }
                }
            }
        }
    }

    private var stashMenu: some View {
        Menu(L("Stash（暂存工作现场）")) {
            Button(L("保存工作现场（含未跟踪文件）…")) {
                if let message = askText(title: L("保存工作现场"), value: "WIP") { run(.saveStash(message)) }
            }.disabled(repository.changes.isEmpty || repository.head == nil || hasConflict)
            ForEach(repository.stashes, id: \.reference) { stash in
                Menu(stash.reference + " · " + stash.title) {
                    Button(L("应用并保留 Stash")) { run(.applyStash(stash.reference, pop: false)) }
                    Button(L("应用并删除 Stash")) { run(.applyStash(stash.reference, pop: true)) }
                    Button(L("删除 Stash…")) {
                        if confirm(title: L("删除 \(stash.reference)？"), detail: L("保存的工作现场将被删除，无法通过此应用恢复。"), action: L("删除")) { run(.dropStash(stash.reference)) }
                    }
                }
            }
        }
    }

    private var tagsMenu: some View {
        Menu(L("Tags（标签）")) {
            Button(L("在 HEAD 创建标签…")) {
                if let name = askText(title: L("创建标签"), value: "") { run(.createTag(name)) }
            }.disabled(repository.head == nil)
            ForEach(repository.tags, id: \.self) { tag in
                Menu(tag) {
                    Button(L("切换到标签（游离 HEAD）")) { run(.checkoutTag(tag)) }
                    Button(L("删除本地标签…")) {
                        if confirm(title: L("删除本地标签 \(tag)？"), detail: L("不会删除远程服务器上的标签。"), action: L("删除标签")) { run(.deleteTag(tag)) }
                    }
                }
            }
        }
    }

    private var worktreesMenu: some View {
        Menu(L("Worktrees（工作树）")) {
            Button(L("新建工作树（游离 HEAD）…")) {
                let panel = NSSavePanel(); panel.title = L("新建 Worktree"); panel.prompt = L("创建")
                panel.nameFieldStringValue = repository.rootURL.lastPathComponent + "-worktree"
                panel.directoryURL = repository.rootURL.deletingLastPathComponent()
                if panel.runModal() == .OK, let url = panel.url { run(.addWorktree(url)) }
            }.disabled(repository.head == nil)
            ForEach(repository.worktrees, id: \.path) { worktree in
                Menu(URL(fileURLWithPath: worktree.path).lastPathComponent + " · " + (worktree.branch ?? L("游离 HEAD"))) {
                    Button(L("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktree.path)]) }
                    Button(L("移除此工作树…")) {
                        if confirm(title: L("移除此工作树？"), detail: L("\(worktree.path)\nGit 会拒绝移除有未提交更改或已锁定的工作树。"), action: L("移除工作树")) {
                            run(.removeWorktree(URL(fileURLWithPath: worktree.path)))
                        }
                    }.disabled(URL(fileURLWithPath: worktree.path).resolvingSymlinksInPath().path == repository.rootURL.resolvingSymlinksInPath().path)
                }
            }
        }
    }

    private func createBranch() {
        select()
        if let name = askText(title: L("新建本地分支"), value: "") { Task { await model.switchBranch(name, create: true, in: repository.rootURL) } }
    }

    private func requestCommit(amend: Bool = false, stageAll: Bool = false) {
        select()
        if amend && !confirm(title: L("修改最近一次提交？"), detail: L("此操作会替换最近提交，提交 ID 会改变。"), action: L("继续")) { return }
        if let message = askText(title: amend ? L("修改最近一次提交") : L("提交到 \(repository.rootURL.lastPathComponent)"), value: model.commitMessage) {
            model.commitMessage = message
            Task { await model.commit(amend: amend, stageAll: stageAll, in: repository.rootURL, message: message) }
        }
    }
}

@MainActor
func askCloneRepository(model: SourceControlModel) {
    guard let source = askText(title: L("克隆仓库地址（HTTPS / SSH / 本地路径）"), value: "") else { return }
    let panel = NSSavePanel(); panel.title = L("克隆到新目录"); panel.prompt = L("克隆")
    let basename = (source as NSString).lastPathComponent
    let suggested = basename.hasSuffix(".git") ? String(basename.dropLast(4)) : basename
    panel.directoryURL = model.directory; panel.nameFieldStringValue = suggested.isEmpty ? "repository" : suggested
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    Task { await model.clone(from: source, to: destination) }
}
