import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import CmuxClone

final class LocalizationTests: XCTestCase {
    func testCatalogContainsBothLanguagesAndMatchingParameters() throws {
        XCTAssertGreaterThan(Localization.messages.count, 400)
        XCTAssertEqual(Set(Localization.messages.values.map(\.zh)).count, Localization.messages.count)
        let regex = try NSRegularExpression(pattern: #"\{\d+\}"#)
        func parameters(_ text: String) -> [String] {
            regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
                .map { (text as NSString).substring(with: $0.range) }.sorted()
        }
        for (key, entry) in Localization.messages {
            XCTAssertFalse(entry.zh.isEmpty, key)
            XCTAssertFalse(entry.en.isEmpty, key)
            XCTAssertNil(entry.en.range(of: #"[\u3400-\u9FFF]"#, options: .regularExpression), key)
            XCTAssertEqual(parameters(entry.zh), parameters(entry.en), key)
            let message = LocalizedMessage(stringLiteral: entry.zh)
            XCTAssertEqual(Localization.render(message, language: .english), entry.en, key)
            XCTAssertEqual(Localization.render(message, language: .chinese), entry.zh, key)
        }
    }

    func testInterpolationReordersParametersWithoutTranslatingOrReinterpretingUserData() {
        let repository = "用户仓库 {0} %@ 🧪"
        let message: LocalizedMessage = "\("推送") \(repository) 的 \(3) 个提交"
        XCTAssertEqual(Localization.render(message, language: .english), "推送 3 commits in \(repository)")
        XCTAssertEqual(Localization.render(message, language: .chinese), "推送 \(repository) 的 3 个提交")
        XCTAssertEqual(Localization.render("没有这个 key：\(repository)", language: .english), "没有这个 key：\(repository)")
    }

    @MainActor func testLanguagePreferencePersistsAndInvalidValuesFallBackToChinese() throws {
        let original = Localization.language
        let suite = "vsux.LocalizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); Localization.setLanguage(original) }
        let preferences = LanguagePreferences(defaults: defaults)
        XCTAssertEqual(preferences.language, .chinese)
        preferences.language = .english
        XCTAssertEqual(defaults.string(forKey: "appLanguage"), "en")
        XCTAssertEqual(LanguagePreferences(defaults: defaults).language, .english)
        XCTAssertEqual(L("设置"), "Settings")
        defaults.set("unsupported", forKey: "appLanguage")
        XCTAssertEqual(LanguagePreferences(defaults: defaults).language, .chinese)
        XCTAssertEqual(L("设置"), "设置")
    }

    @MainActor func testNativeMenuSwitchUpdatesOpenEditorWithoutReplacingShellOrUserData() async throws {
        _ = NSApplication.shared
        let preferences = LanguagePreferences.shared
        let original = preferences.language
        let originalDefault = UserDefaults.standard.object(forKey: "appLanguage")
        defer {
            preferences.language = original
            if let originalDefault { UserDefaults.standard.set(originalDefault, forKey: "appLanguage") }
            else { UserDefaults.standard.removeObject(forKey: "appLanguage") }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vsux-language-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("中文文件.swift")
        try Data("let value = 1\n".utf8).write(to: file)
        let model = WindowModel(workspaces: [Workspace(name: "我的项目 My Project", directory: root.path)], shellCommand: "/bin/zsh -f")
        let controller = TerminalWindowController(model: model)
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        defer { model.disposeAll(); window.orderOut(nil) }
        let pane = try XCTUnwrap(model.selectedTab?.focusedPane)
        let terminal = model.terminal(model.activeTerminalID(pane))
        let deadline = Date().addingTimeInterval(5)
        while terminal.surface == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        let surface = try XCTUnwrap(terminal.surface)
        let files = model.tools.files(try XCTUnwrap(model.workspace))
        files.open(file, preview: false)
        let document = try XCTUnwrap(files.selectedDocument)
        files.update(document, text: "let 中文变量 = \"user data {0} %@\"\n")
        model.tools.content = .editor; model.tools.sidebar = .files
        let tabs = model.workspaces
        AppDelegate.shared.makeMenus()
        for language in [AppLanguage.english, .chinese, .english] {
            let languageMenu = try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu?.items.first { $0.submenu?.items.contains { $0.representedObject as? String == language.rawValue } == true }?.submenu)
            let item = try XCTUnwrap(languageMenu.items.first { $0.representedObject as? String == language.rawValue })
            NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(preferences.language, language)
            XCTAssertEqual(NSApp.mainMenu?.items[1].title, language == .english ? "Files" : "文件")
            XCTAssertEqual(NSApp.mainMenu?.items[2].title, language == .english ? "Edit" : "编辑")
            XCTAssertEqual(model.workspaces, tabs)
            XCTAssertEqual(model.workspace?.name, "我的项目 My Project")
            XCTAssertTrue(files.selectedDocument === document)
            XCTAssertTrue(document.isDirty)
            XCTAssertEqual(document.text, "let 中文变量 = \"user data {0} %@\"\n")
            XCTAssertTrue(model.terminals[terminal.paneID] === terminal)
            XCTAssertEqual(terminal.surface, surface)
            let host = try XCTUnwrap(window.contentView)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/i18n-editor-\(language.catalogCode).png"))
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let value = 1\n")
    }

    @MainActor func testMarkdownPreviewChangesItsControlsAndPreservesDocumentContents() async throws {
        _ = NSApplication.shared
        let preferences = LanguagePreferences.shared
        let original = preferences.language
        let originalDefault = UserDefaults.standard.object(forKey: "appLanguage")
        defer {
            preferences.language = original
            if let originalDefault { UserDefaults.standard.set(originalDefault, forKey: "appLanguage") }
            else { UserDefaults.standard.removeObject(forKey: "appLanguage") }
        }
        let root = FileManager.default.temporaryDirectory
        let source = "# 用户标题\n\n```swift\nlet 中文 = 1\n```"
        let host = NSHostingView(rootView: MarkdownPreview(source: source, documentURL: root.appendingPathComponent("test.md"), rootURL: root))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil) }
        func webViews(_ view: NSView) -> [WKWebView] {
            (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { webViews($0) }
        }
        let initialDeadline = Date().addingTimeInterval(5)
        while webViews(host).isEmpty && Date() < initialDeadline { try await Task.sleep(for: .milliseconds(25)) }
        let web = try XCTUnwrap(webViews(host).first)
        for language in [AppLanguage.english, .chinese] {
            preferences.language = language
            let expected = language == .english ? "Copy" : "复制"
            let deadline = Date().addingTimeInterval(8)
            var text = ""
            while text != expected && Date() < deadline {
                text = (try? await web.evaluateJavaScript("document.querySelector('.copy-code')?.textContent")) as? String ?? ""
                if text != expected { try await Task.sleep(for: .milliseconds(40)) }
            }
            XCTAssertEqual(text, expected)
            let heading = try await web.evaluateJavaScript("document.querySelector('h1').textContent") as? String
            XCTAssertEqual(heading, "用户标题")
            XCTAssertTrue(webViews(host).first === web)
        }
    }

    @MainActor func testSettingsAndSourceControlRenderInBothLanguages() async throws {
        _ = NSApplication.shared
        let language = LanguagePreferences.shared
        let original = language.language
        let originalDefault = UserDefaults.standard.object(forKey: "appLanguage")
        let suite = "vsux.LocalizationSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            language.language = original
            if let originalDefault { UserDefaults.standard.set(originalDefault, forKey: "appLanguage") }
            else { UserDefaults.standard.removeObject(forKey: "appLanguage") }
            defaults.removePersistentDomain(forName: suite)
        }
        let preferences = Preferences(defaults: defaults)
        let settings = NSHostingView(rootView: SettingsView(preferences: preferences))
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("vsux-i18n-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "--initial-branch=main", project.path]
        git.standardOutput = FileHandle.nullDevice; git.standardError = FileHandle.nullDevice
        try git.run(); git.waitUntilExit(); XCTAssertEqual(git.terminationStatus, 0)
        try Data("let sample = 1\n".utf8).write(to: project.appendingPathComponent("Sample.swift"))
        let repository = SourceControlModel(directory: project)
        await repository.refresh()
        XCTAssertEqual(repository.repositories.count, 1)
        let control = NSHostingView(rootView: SourceControlPanel(model: repository, openFile: { _ in }, showDiff: {}))
        func capture(_ host: NSView, name: String, size: NSSize) throws {
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/i18n-\(name)-\(language.language.catalogCode).png"))
        }
        for locale in [AppLanguage.english, .chinese] {
            language.language = locale
            try await Task.sleep(for: .milliseconds(70))
            try capture(settings, name: "settings", size: NSSize(width: 510, height: 700))
            try capture(control, name: "git", size: NSSize(width: 360, height: 600))
            XCTAssertEqual(WorkspaceSidebarSection.git.title, locale == .english ? "Source Control" : "源代码管理")
            XCTAssertEqual(GitCheckoutReference.Kind.local.title, locale == .english ? "Local Branches" : "本地分支")
            XCTAssertEqual(CodeLanguage.plain.title, locale == .english ? "Plain Text" : "纯文本")
            let userTab = TerminalTab(title: "用户终端")
            XCTAssertEqual(userTab.displayTitle, "用户终端")
            XCTAssertEqual(TerminalTab().displayTitle, locale == .english ? "Terminal" : "终端")
        }
    }
}
