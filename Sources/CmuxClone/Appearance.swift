import AppKit
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self { case .system: return L("跟随系统"); case .light: return L("浅色"); case .dark: return L("深色") }
    }
    var symbol: String {
        switch self { case .system: return "circle.lefthalf.filled"; case .light: return "sun.max"; case .dark: return "moon" }
    }
    var nativeAppearance: NSAppearance? {
        switch self { case .system: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) }
    }
    func isDark(systemAppearance: NSAppearance) -> Bool {
        switch self {
        case .system: return systemAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        case .light: return false
        case .dark: return true
        }
    }
}

struct AppearanceMenu: View {
    @ObservedObject private var languagePreferences = LanguagePreferences.shared
    @ObservedObject var preferences: Preferences
    var body: some View {
        let _ = languagePreferences.language
        Menu {
            Picker(L("外观"), selection: $preferences.appearance) {
                ForEach(AppAppearance.allCases) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode) }
            }.pickerStyle(.inline)
        } label: {
            Image(systemName: preferences.appearance.symbol)
                .font(.system(size: 12, weight: .medium)).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().pointingHandCursor()
        .help(L("外观：\(preferences.appearance.title)")).accessibilityLabel(L("切换外观，当前\(preferences.appearance.title)"))
    }
}
