import Foundation

/// Git operations for the workspace sidebar. Commands use argv, never a shell.
actor LocalGitRepository {
    nonisolated let rootURL: URL
    private let environmentOverrides: [String: String]
    private let shellEnvironment: ShellEnvironment
    private var commandLog: [String] = []

    init(rootURL: URL, environment: [String: String] = [:], shellEnvironment: ShellEnvironment = .shared) {
        self.rootURL = rootURL.standardizedFileURL
        self.environmentOverrides = environment
        self.shellEnvironment = shellEnvironment
    }

    static func discover(at directory: URL, environment: [String: String] = [:]) async throws -> LocalGitRepository {
        let result = try runGit(at: directory, arguments: ["rev-parse", "--show-toplevel"], environment: environment)
        guard result.status == 0 else { throw LocalGitError.notRepository(directory) }
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw LocalGitError.notRepository(directory) }
        let repository = LocalGitRepository(rootURL: URL(fileURLWithPath: path, isDirectory: true), environment: environment)
        let inside = try await repository.runGit(["rev-parse", "--is-inside-work-tree"])
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard inside == "true" else { throw LocalGitError.notRepository(directory) }
        return repository
    }

    // Only prune known dependency/cache containers when descending. An explicitly
    // opened workspace is always scanned, even if its name appears here.
    private static let repositoryScanExcludedDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", "node_modules", "DerivedData",
        ".gradle", ".venv", "venv", "__pycache__", ".cache",
        ".next", ".nuxt", ".turbo", ".dart_tool", "Pods", "Carthage"
    ]

    /// Finds the repository containing the workspace and independent repositories
    /// nested beneath it. A repository is identified by its `.git` directory or
    /// worktree `.git` file, so worktrees and submodules are included as well.
    /// Dependency and build-cache containers are excluded from recursive discovery.
    static func discoverAll(in directory: URL, environment: [String: String] = [:]) async throws -> [LocalGitRepository] {
        let fileManager = FileManager.default
        let workspaceRoot = directory.standardizedFileURL
        var repositoriesByPath: [String: LocalGitRepository] = [:]
        var enclosingPath: String?

        // Preserve the useful case where a workspace is itself a subdirectory of
        // a repository whose root is outside the workspace.
        if let enclosing = try? await discover(at: workspaceRoot, environment: environment) {
            repositoriesByPath[enclosing.rootURL.standardizedFileURL.path] = enclosing
            enclosingPath = enclosing.rootURL.standardizedFileURL.path
        }

        var pendingDirectories = [workspaceRoot]
        while let current = pendingDirectories.popLast() {
            let gitMarker = current.appendingPathComponent(".git", isDirectory: false)
            if fileManager.fileExists(atPath: gitMarker.path),
               let repository = try? await discover(at: current, environment: environment) {
                repositoriesByPath[repository.rootURL.standardizedFileURL.path] = repository
            }

            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: current,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: []
                )
            } catch {
                if current == workspaceRoot { throw error }
                continue
            }

            for child in children {
                guard !repositoryScanExcludedDirectories.contains(child.lastPathComponent),
                      let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true,
                      values.isSymbolicLink != true else { continue }
                pendingDirectories.append(child)
            }
        }

        return repositoriesByPath.values.sorted {
            let left = $0.rootURL.standardizedFileURL.path
            let right = $1.rootURL.standardizedFileURL.path
            if left == enclosingPath { return true }
            if right == enclosingPath { return false }
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }

    func snapshot() throws -> LocalGitSnapshot {
        let branchOutput = try runGit(["branch", "--show-current"]).output
        let branchName = branchOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let headResult = try runGit(["rev-parse", "--verify", "HEAD"], allowFailure: true)
        let head = headResult.status == 0
            ? headResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let branchOutputList = try runGit(["for-each-ref", "--format=%(refname:short)", "refs/heads"])
            .output
        let branches = branchOutputList
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        let status = try runGit(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        let tags = try runGit(["tag", "--list"]).output.split(whereSeparator: \.isNewline).map(String.init)
        let stashes = try runGit(["stash", "list", "--format=%gd%x00%gs"]).output
            .split(whereSeparator: \.isNewline).compactMap { line -> LocalGitStash? in
                let parts = line.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                return LocalGitStash(reference: String(parts[0]), title: String(parts[1]))
            }
        let worktrees = Self.parseWorktrees(try runGit(["worktree", "list", "--porcelain", "-z"]).output)
        let remotes = try runGit(["remote"]).output.split(whereSeparator: \.isNewline).map(String.init)
        let remoteBranches = try runGit(["for-each-ref", "--format=%(refname)", "refs/remotes"]).output
            .split(whereSeparator: \.isNewline).map { String($0.dropFirst("refs/remotes/".count)) }
            .filter { !$0.hasSuffix("/HEAD") }
        let gitPath = try runGit(["rev-parse", "--absolute-git-dir"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let merging = FileManager.default.fileExists(atPath: gitPath + "/MERGE_HEAD")
        let rebasing = FileManager.default.fileExists(atPath: gitPath + "/rebase-merge") || FileManager.default.fileExists(atPath: gitPath + "/rebase-apply")
        let tracking = try trackingStatus(branch: branchName, hasHead: head != nil)
        return LocalGitSnapshot(
            rootURL: rootURL,
            branch: branchName.isEmpty ? nil : branchName,
            head: head?.isEmpty == true ? nil : head,
            branches: branches,
            changes: Self.parseStatus(status.data), tags: tags, stashes: stashes, worktrees: worktrees, remotes: remotes,
            remoteBranches: remoteBranches, isMerging: merging, isRebasing: rebasing, tracking: tracking
        )
    }

    private func trackingStatus(branch: String, hasHead: Bool) throws -> GitTrackingStatus? {
        guard !branch.isEmpty, hasHead else { return nil }
        let fields = try runGit(["for-each-ref", "--format=%(upstream)%09%(upstream:short)%09%(upstream:remotename)%09%(upstream:remoteref)", "--", "refs/heads/" + branch])
            .output.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
        guard fields.count == 4, !fields[0].isEmpty, !fields[2].isEmpty else { return nil }
        let result = try runGit(["rev-list", "--left-right", "--count", "HEAD...@{upstream}", "--"], allowFailure: true)
        let counts = result.output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        let available = result.status == 0 && counts.count == 2
        return GitTrackingStatus(upstream: fields[1], remote: fields[2], remoteRef: fields[3],
                                 ahead: available ? counts[0] : nil, behind: available ? counts[1] : nil)
    }

    func stage(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try validate(paths)
        _ = try runGit(["add", "--"] + (try includingRenameSources(paths)))
    }

    func unstage(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try validate(paths)
        let paths = try includingRenameSources(paths)
        let head = try runGit(["rev-parse", "--verify", "HEAD"], allowFailure: true)
        if head.status == 0 {
            _ = try runGit(["restore", "--staged", "--"] + paths)
        } else {
            // On an unborn branch there is no HEAD for `restore --staged` to use.
            _ = try runGit(["rm", "--cached", "--force", "--ignore-unmatch", "--"] + paths)
        }
    }

    /// Commits the current index only. Unstaged working-tree edits are left alone.
    func commit(message: String, amend: Bool = false) throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalGitError.emptyCommitMessage
        }
        _ = try runGit(["commit"] + (amend ? ["--amend"] : []) + ["-m", message])
    }

    func diff(path: String? = nil, staged: Bool = false) throws -> String {
        if let path, !staged {
            try validate([path])
            if try snapshot().changes.contains(where: { $0.path == path && $0.isUntracked }) {
                let result = try runGit(["diff", "--no-index", "--no-color", "--no-ext-diff", "--no-textconv", "--", "/dev/null", path], allowFailure: true)
                guard result.status == 0 || result.status == 1 else {
                    throw LocalGitError.commandFailed(arguments: ["diff"], status: result.status, output: result.output)
                }
                return result.output
            }
        }
        var arguments = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--unified=3"]
        if staged { arguments.append("--cached") }
        arguments.append("--")
        if let path {
            try validate([path])
            arguments.append(path)
        }
        return try runGit(arguments).output
    }

    /// Switches to an existing local branch, or creates one when `create` is true.
    func checkout(branch: String, create: Bool = false, startPoint: String? = nil) throws {
        guard !branch.isEmpty,
              try runGit(["check-ref-format", "--branch", branch], allowFailure: true).status == 0 else {
            throw LocalGitError.invalidBranch(branch)
        }
        if create {
            let commit = try startPoint.map { try resolveCommit($0) }
            _ = try runGit(["switch", "-c", branch] + (commit.map { [$0] } ?? []))
        } else {
            _ = try runGit(["switch", branch])
        }
    }

    /// Read commit details for the checkout picker without fetching or changing refs.
    func checkoutReferences() throws -> [GitCheckoutReference] {
        let format = "%(refname)%00%(objectname:short)%00%(committerdate:unix)%00%(authorname)%00%(subject)%00%(*objectname:short)%00%(*committerdate:unix)%00%(*authorname)%00%(*subject)"
        return try runGit(["for-each-ref", "--sort=-committerdate", "--format=" + format, "refs/heads", "refs/remotes", "refs/tags"]).output
            .split(whereSeparator: \.isNewline).compactMap { line in
                let fields = line.components(separatedBy: "\0")
                guard fields.count == 9 else { return nil }
                let kind: GitCheckoutReference.Kind
                let prefix: String
                if fields[0].hasPrefix("refs/heads/") { kind = .local; prefix = "refs/heads/" }
                else if fields[0].hasPrefix("refs/remotes/") {
                    guard !fields[0].hasSuffix("/HEAD") else { return nil }
                    kind = .remote; prefix = "refs/remotes/"
                } else { kind = .tag; prefix = "refs/tags/" }
                let peeled = !fields[5].isEmpty
                return GitCheckoutReference(id: fields[0], name: String(fields[0].dropFirst(prefix.count)), kind: kind,
                    shortHash: fields[peeled ? 5 : 1], author: fields[peeled ? 7 : 3],
                    subject: fields[peeled ? 8 : 4], timestamp: TimeInterval(fields[peeled ? 6 : 2]).map { Date(timeIntervalSince1970: $0) })
            }
    }

    private func resolveCommit(_ reference: String) throws -> String {
        guard !reference.isEmpty else { throw LocalGitError.invalidValue(L("提交或引用")) }
        return try runGit(["rev-parse", "--verify", "--end-of-options", reference + "^{commit}"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func outputLog() -> String {
        commandLog.isEmpty ? L("尚无 Git 命令输出。") : commandLog.joined(separator: "\n\n")
    }

    func history() throws -> String {
        try runGit(["log", "-50", "--date=short", "--format=%h %ad %s (%an)", "--no-decorate"]).output
    }

    static func clone(from source: String, to destination: URL, environment: [String: String] = [:]) async throws -> LocalGitRepository {
        try validateRemoteURL(source)
        guard destination.isFileURL, !FileManager.default.fileExists(atPath: destination.path) else {
            throw LocalGitError.invalidValue(L("克隆目标目录必须尚不存在"))
        }
        let result = try runGit(at: destination.deletingLastPathComponent(), arguments: ["clone", "--", source, destination.path], environment: environment)
        guard result.status == 0 else {
            throw LocalGitError.commandFailed(arguments: ["clone"], status: result.status, output: result.output)
        }
        return try await discover(at: destination, environment: environment)
    }

    func perform(_ operation: LocalGitOperation) throws {
        switch operation {
        case .renameBranch(let old, let new):
            try validateBranch(new)
            guard try snapshot().branches.contains(old) else { throw LocalGitError.invalidBranch(old) }
            _ = try runGit(["branch", "-m", old, new])
        case .deleteBranch(let branch):
            try validateBranch(branch)
            _ = try runGit(["branch", "-d", branch])
        case .saveStash(let message):
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalGitError.invalidValue(L("暂存说明")) }
            _ = try runGit(["stash", "push", "--include-untracked", "-m", message])
        case .applyStash(let reference, let pop):
            guard try snapshot().stashes.contains(where: { $0.reference == reference }) else { throw LocalGitError.invalidValue("Stash") }
            _ = try runGit(["stash", pop ? "pop" : "apply", reference])
        case .dropStash(let reference):
            guard try snapshot().stashes.contains(where: { $0.reference == reference }) else { throw LocalGitError.invalidValue("Stash") }
            _ = try runGit(["stash", "drop", reference])
        case .createTag(let name):
            try validateTag(name)
            _ = try runGit(["tag", name])
        case .deleteTag(let name):
            try validateTag(name)
            _ = try runGit(["tag", "-d", name])
        case .addWorktree(let destination):
            guard destination.isFileURL, (destination.path as NSString).isAbsolutePath,
                  !FileManager.default.fileExists(atPath: destination.path) else {
                throw LocalGitError.invalidValue(L("Worktree 目标目录必须尚不存在"))
            }
            _ = try runGit(["worktree", "add", "--detach", "--", destination.standardizedFileURL.path, "HEAD"])
        case .removeWorktree(let directory):
            let path = directory.standardizedFileURL.resolvingSymlinksInPath().path
            guard path != rootURL.resolvingSymlinksInPath().path,
                  try snapshot().worktrees.contains(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == path }) else {
                throw LocalGitError.invalidValue("Worktree")
            }
            _ = try runGit(["worktree", "remove", "--", path])
        case .fetch(let remote):
            try validateRemote(remote)
            _ = try runGit(["fetch", "--prune", remote])
        case .fetchAll:
            _ = try runGit(["fetch", "--all", "--prune"])
        case .pull(let rebase):
            _ = try runGit(["pull", rebase ? "--rebase" : "--ff-only"])
        case .pushUpstream:
            let state = try snapshot()
            guard state.branch != nil, let tracking = state.tracking,
                  tracking.remoteRef.hasPrefix("refs/heads/") else { throw LocalGitError.invalidValue(L("当前分支尚未设置上游，请先发布分支")) }
            try validateRemote(tracking.remote)
            // Honor an upstream whose branch name differs from the local one.
            _ = try runGit(["push", tracking.remote, "HEAD:" + tracking.remoteRef])
        case .push(let remote, let tags):
            try validateRemote(remote)
            if tags {
                _ = try runGit(["push", remote, "--tags"])
            } else {
                guard let branch = try snapshot().branch else { throw LocalGitError.invalidValue(L("游离 HEAD 无法发布分支")) }
                _ = try runGit(["push", "--set-upstream", remote, "HEAD:refs/heads/" + branch])
            }
        case .addRemote(let name, let url):
            try validateRemoteName(name); try Self.validateRemoteURL(url)
            _ = try runGit(["remote", "add", "--", name, url])
        case .removeRemote(let name):
            try validateRemote(name)
            _ = try runGit(["remote", "remove", name])
        case .renameRemote(let old, let new):
            try validateRemote(old); try validateRemoteName(new)
            _ = try runGit(["remote", "rename", old, new])
        case .setRemoteURL(let name, let url):
            try validateRemote(name); try Self.validateRemoteURL(url)
            _ = try runGit(["remote", "set-url", name, url])
        case .mergeBranch(let branch):
            try validateBranch(branch)
            _ = try runGit(["merge", "--no-edit", branch])
        case .rebaseBranch(let branch):
            try validateBranch(branch)
            _ = try runGit(["rebase", branch])
        case .abortMerge:
            _ = try runGit(["merge", "--abort"])
        case .abortRebase:
            _ = try runGit(["rebase", "--abort"])
        case .continueRebase:
            _ = try runGit(["-c", "core.editor=true", "rebase", "--continue"])
        case .undoCommit:
            _ = try runGit(["reset", "--soft", "HEAD~1"])
        case .discardTracked(let paths):
            try validate(paths)
            let changes = try snapshot().changes
            guard !paths.isEmpty, paths.allSatisfy({ path in changes.contains { $0.path == path && !$0.isUntracked && !$0.isConflicted } }) else {
                throw LocalGitError.invalidValue(L("还原文件列表"))
            }
            _ = try runGit(["restore", "--worktree", "--"] + (try includingRenameSources(paths)))
        case .discardUntracked(let paths):
            try validate(paths)
            let changes = try snapshot().changes
            guard !paths.isEmpty, paths.allSatisfy({ path in changes.contains { $0.path == path && $0.isUntracked } }) else {
                throw LocalGitError.invalidValue(L("未跟踪文件列表"))
            }
            for path in paths { try FileManager.default.trashItem(at: rootURL.appendingPathComponent(path), resultingItemURL: nil) }
        case .checkoutRemote(let branch):
            guard try snapshot().remoteBranches.contains(branch) else { throw LocalGitError.invalidBranch(branch) }
            _ = try runGit(["switch", "--track", branch])
        case .checkoutTag(let tag):
            try validateTag(tag)
            _ = try runGit(["switch", "--detach", "refs/tags/" + tag])
        case .checkoutDetached(let reference):
            _ = try runGit(["switch", "--detach", resolveCommit(reference)])
        }
    }

    func remoteURL(_ name: String) throws -> String {
        try validateRemote(name)
        return Self.redact(try runGit(["remote", "get-url", name]).output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func validateRemote(_ name: String) throws {
        try validateRemoteName(name)
        guard try runGit(["remote"]).output.split(whereSeparator: \.isNewline).contains(Substring(name)) else {
            throw LocalGitError.invalidValue(L("远程仓库名称"))
        }
    }

    private func validateRemoteName(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains(where: { $0.isWhitespace || $0 == "\0" }),
              try runGit(["check-ref-format", "refs/remotes/" + name + "/test"], allowFailure: true).status == 0 else {
            throw LocalGitError.invalidValue(L("远程仓库名称"))
        }
    }

    private static func validateRemoteURL(_ value: String) throws {
        guard !value.isEmpty, !value.hasPrefix("-"), !value.contains("\0"), !value.contains("\n"), !value.contains("::") else {
            throw LocalGitError.invalidValue(L("仓库地址"))
        }
        if let scheme = URLComponents(string: value)?.scheme, value.contains("://"),
           !["https", "http", "ssh", "git", "file"].contains(scheme.lowercased()) {
            throw LocalGitError.invalidValue(L("仓库地址协议"))
        }
    }

    static func redact(_ value: String) -> String {
        value.replacingOccurrences(of: #"(https?://)[^\s/@]+@"#, with: "$1<REDACTED>@", options: .regularExpression)
            .replacingOccurrences(of: #"([?&](?:access_token|token|password)=)[^&\s]+"#, with: "$1<REDACTED>", options: .regularExpression)
    }

    private func validateBranch(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains("\0"),
              try runGit(["check-ref-format", "--branch", name], allowFailure: true).status == 0 else {
            throw LocalGitError.invalidBranch(name)
        }
    }

    private func validateTag(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains("\0"),
              try runGit(["check-ref-format", "refs/tags/" + name], allowFailure: true).status == 0 else {
            throw LocalGitError.invalidValue(L("标签名称"))
        }
    }

    private static func parseWorktrees(_ output: String) -> [LocalGitWorktree] {
        var result: [LocalGitWorktree] = []
        var path: String?
        var branch: String?
        for field in output.split(separator: "\0", omittingEmptySubsequences: false) {
            if field.hasPrefix("worktree ") {
                path = String(field.dropFirst(9)); branch = nil
            } else if field.hasPrefix("branch refs/heads/") {
                branch = String(field.dropFirst(18))
            } else if field.isEmpty, let value = path {
                result.append(LocalGitWorktree(path: value, branch: branch))
                path = nil; branch = nil
            }
        }
        return result
    }

    private func validate(_ paths: [String]) throws {
        for path in paths {
            guard !path.isEmpty,
                  !path.contains("\0"),
                  !(path as NSString).isAbsolutePath,
                  path != "..",
                  !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
                throw LocalGitError.invalidPath(path)
            }
        }
    }

    private func includingRenameSources(_ paths: [String]) throws -> [String] {
        let selected = Set(paths)
        let sources = try snapshot().changes.compactMap { change in
            selected.contains(change.path) ? change.previousPath : nil
        }
        return Array(Set(paths + sources)).sorted()
    }

    private func runGit(_ arguments: [String], allowFailure: Bool = false) throws -> LocalGitCommandResult {
        let result = try Self.runGit(at: rootURL, arguments: arguments, environment: environmentOverrides, shellEnvironment: shellEnvironment)
        let entry = Self.redact("$ git " + arguments.joined(separator: " ") + "\n" +
            (arguments.contains("-z") ? L("[已读取结构化状态]") : String(result.output.prefix(32_768))) +
            L("\n[退出码 \(result.status)]"))
        commandLog.append(entry)
        if commandLog.count > 60 { commandLog.removeFirst(commandLog.count - 60) }
        if result.status != 0 && !allowFailure {
            throw LocalGitError.commandFailed(arguments: arguments, status: result.status, output: result.output)
        }
        return result
    }

    private static func runGit(at directory: URL, arguments: [String], environment overrides: [String: String], shellEnvironment: ShellEnvironment = .shared) throws -> LocalGitCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // Status refreshes must not execute a repository-configured monitor.
        // Explicit mutations still retain normal Git hooks and credential helpers.
        process.arguments = ["git", "-C", directory.standardizedFileURL.path, "-c", "core.quotepath=false", "-c", "core.fsmonitor=false"] + arguments
        var environment = shellEnvironment.resolve()
        environment.merge(overrides, uniquingKeysWith: { _, new in new })
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        // Stash invokes internal Git commands with generated pathspecs. Applying
        // literal mode to the entire process tree breaks its untracked cleanup.
        if ["add", "restore", "rm", "diff"].contains(arguments.first ?? "") {
            environment["GIT_LITERAL_PATHSPECS"] = "1"
        } else {
            environment.removeValue(forKey: "GIT_LITERAL_PATHSPECS")
        }
        environment["GCM_INTERACTIVE"] = "never"
        environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=15"
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_PREFIX", "GIT_NAMESPACE"] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        do {
            try process.run()
        } catch {
            throw LocalGitError.cannotLaunchGit(error.localizedDescription)
        }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: deadline)
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        let output = redact(String(decoding: data, as: UTF8.self))
        return LocalGitCommandResult(status: process.terminationStatus, data: data, output: output)
    }

    private static func parseStatus(_ data: Data) -> [LocalGitChange] {
        let records = splitNullTerminated(data)
        var changes: [LocalGitChange] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard record.count >= 3, record[2] == 0x20 else { continue }
            let x = Character(UnicodeScalar(record[0]))
            let y = Character(UnicodeScalar(record[1]))
            let path = String(decoding: record.dropFirst(3), as: UTF8.self)
            guard !path.isEmpty else { continue }
            let isUntracked = x == "?" && y == "?"
            if x == "!" && y == "!" { continue }

            var previousPath: String?
            if x == "R" || x == "C" || y == "R" || y == "C" {
                if index < records.count {
                    previousPath = String(decoding: records[index], as: UTF8.self)
                    index += 1
                }
            }
            let hasConflict = x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D")
            changes.append(LocalGitChange(
                path: path,
                previousPath: previousPath,
                indexStatus: x,
                worktreeStatus: y,
                isUntracked: isUntracked,
                isConflicted: hasConflict
            ))
        }
        return changes
    }

    private static func splitNullTerminated(_ data: Data) -> [[UInt8]] {
        var records: [[UInt8]] = []
        var current: [UInt8] = []
        for byte in data {
            if byte == 0 {
                records.append(current)
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
        }
        if !current.isEmpty { records.append(current) }
        return records
    }
}

struct LocalGitSnapshot: Identifiable, Equatable, Sendable {
    var id: String { rootURL.path }
    var hasUncommittedChanges: Bool { !changes.isEmpty }
    var branchDisplayName: String { (branch ?? "HEAD") + (hasUncommittedChanges ? "*" : "") }
    let rootURL: URL
    let branch: String?
    let head: String?
    let branches: [String]
    let changes: [LocalGitChange]
    var tags: [String] = []
    var stashes: [LocalGitStash] = []
    var worktrees: [LocalGitWorktree] = []
    var remotes: [String] = []
    var remoteBranches: [String] = []
    var isMerging = false
    var isRebasing = false
    var tracking: GitTrackingStatus?
    var hasSyncChanges: Bool { (tracking?.ahead ?? 0) > 0 || (tracking?.behind ?? 0) > 0 }
    var canPublishBranch: Bool { branch != nil && head != nil && tracking == nil && !remotes.isEmpty }
}

struct GitTrackingStatus: Equatable, Sendable {
    let upstream: String
    let remote: String
    let remoteRef: String
    let ahead: Int?
    let behind: Int?
}

struct LocalGitStash: Equatable, Sendable {
    let reference: String
    let title: String
}

struct GitCheckoutReference: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case local = "本地分支", remote = "远程分支", tag = "标签"
        var title: String {
            switch self { case .local: return L("本地分支"); case .remote: return L("远程分支"); case .tag: return L("标签") }
        }
    }
    let id: String
    let name: String
    let kind: Kind
    let shortHash: String
    let author: String
    let subject: String
    let timestamp: Date?
}

struct LocalGitWorktree: Equatable, Sendable {
    let path: String
    let branch: String?
}

enum LocalGitOperation: Sendable {
    case renameBranch(String, String), deleteBranch(String)
    case saveStash(String), applyStash(String, pop: Bool), dropStash(String)
    case createTag(String), deleteTag(String)
    case addWorktree(URL), removeWorktree(URL)
    case fetch(String), fetchAll, pull(rebase: Bool), push(String, tags: Bool), pushUpstream
    case addRemote(String, String), removeRemote(String), renameRemote(String, String), setRemoteURL(String, String)
    case mergeBranch(String), rebaseBranch(String), abortMerge, abortRebase, continueRebase
    case undoCommit, discardTracked([String]), discardUntracked([String])
    case checkoutRemote(String), checkoutTag(String), checkoutDetached(String)
}

struct LocalGitChange: Identifiable, Equatable, Sendable {
    var id: String { path }
    let path: String
    let previousPath: String?
    let indexStatus: Character
    let worktreeStatus: Character
    let isUntracked: Bool
    let isConflicted: Bool

    var isStaged: Bool { indexStatus != " " && indexStatus != "?" && indexStatus != "!" }
    var isUnstaged: Bool { isUntracked || (worktreeStatus != " " && worktreeStatus != "?" && worktreeStatus != "!") }
    var status: String { String(indexStatus) + String(worktreeStatus) }
}

private struct LocalGitCommandResult {
    let status: Int32
    let data: Data
    let output: String
}

enum LocalGitError: LocalizedError {
    case notRepository(URL)
    case invalidPath(String)
    case invalidBranch(String)
    case emptyCommitMessage
    case invalidValue(String)
    case cannotLaunchGit(String)
    case commandFailed(arguments: [String], status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .notRepository(let url):
            return L("不是可用的本地 Git 工作区：\(url.path)")
        case .invalidPath(let path):
            return L("无效的仓库相对路径：\(path)")
        case .invalidBranch(let branch):
            return L("无效的本地分支名称：\(branch)")
        case .emptyCommitMessage:
            return L("提交说明不能为空。")
        case .invalidValue(let detail):
            return L("无效的 Git 操作参数：\(detail)")
        case .cannotLaunchGit(let detail):
            return L("无法启动 Git：\(detail)")
        case .commandFailed(_, let status, let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? L("Git 命令失败（退出码 \(status)）。") : detail
        }
    }
}
