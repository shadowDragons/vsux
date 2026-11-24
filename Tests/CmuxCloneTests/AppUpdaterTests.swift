import AppKit
import XCTest
@testable import CmuxClone

final class AppUpdaterTests: XCTestCase {
    @MainActor func testSourceBuildsAndInvalidConfigurationCannotStartNetworkUpdates() {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        XCTAssertFalse(AppUpdater.hasConfiguration([:]))
        XCTAssertFalse(AppUpdater.hasConfiguration(["SUFeedURL": "https://github.com/example/app/appcast.xml"]))
        XCTAssertFalse(AppUpdater.hasConfiguration(["SUFeedURL": "http://example.com/feed", "SUPublicEDKey": key]))
        XCTAssertFalse(AppUpdater.hasConfiguration(["SUFeedURL": "https://example.com/feed", "SUPublicEDKey": "invalid"]))
        XCTAssertFalse(AppUpdater.hasConfiguration(["SUFeedURL": "https://example.com/feed", "SUPublicEDKey": Data(repeating: 1, count: 16).base64EncodedString()]))
        XCTAssertTrue(AppUpdater.hasConfiguration(["SUFeedURL": "https://github.com/example/app/releases/latest/download/appcast.xml", "SUPublicEDKey": key]))
    }

    @MainActor func testUpdateMenuIsAvailableWithoutAnOpenWorkspaceInBothLanguages() throws {
        _ = NSApplication.shared
        let original = LanguagePreferences.shared.language
        defer { LanguagePreferences.shared.language = original }
        for language in [AppLanguage.chinese, .english] {
            LanguagePreferences.shared.language = language
            AppDelegate.shared.makeMenus()
            let item = try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu?.items.first {
                $0.action == #selector(AppDelegate.checkForUpdates(_:))
            })
            XCTAssertEqual(item.title, language == .english ? "Check for Updates…" : "检查更新…")
            XCTAssertTrue(AppDelegate.shared.validateMenuItem(item))
        }
    }
}
