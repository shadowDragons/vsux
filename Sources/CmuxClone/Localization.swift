import AppKit
import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case chinese = "zh-Hans"
    case english = "en"
    var id: String { rawValue }
    var title: String { self == .chinese ? "简体中文" : "English" }
    var catalogCode: String { self == .chinese ? "zh" : "en" }
    var locale: Locale { Locale(identifier: rawValue) }
}

extension Notification.Name {
    static let appLanguageDidChange = Notification.Name("vsux.appLanguageDidChange")
}

@MainActor
final class LanguagePreferences: ObservableObject {
    static let shared = LanguagePreferences()
    private let defaults: UserDefaults
    @Published var language: AppLanguage {
        didSet {
            guard oldValue != language else { return }
            defaults.set(language.rawValue, forKey: "appLanguage")
            Localization.setLanguage(language)
            NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Keep the existing Chinese UI until the user explicitly changes it.
        language = defaults.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .chinese
        Localization.setLanguage(language)
    }
}

/// Interpolation keeps user data separate from the translated message template.
struct LocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let template: String
    let arguments: [String]

    init(stringLiteral value: String) { template = value; arguments = [] }
    init(stringInterpolation: StringInterpolation) {
        template = stringInterpolation.template; arguments = stringInterpolation.arguments
    }

    struct StringInterpolation: StringInterpolationProtocol {
        var template = ""
        var arguments: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) {
            template.reserveCapacity(literalCapacity)
            arguments.reserveCapacity(interpolationCount)
        }
        mutating func appendLiteral(_ literal: String) { template += literal }
        mutating func appendInterpolation<T>(_ value: T) {
            template += "{\(arguments.count)}"
            arguments.append(String(describing: value))
        }
    }
}

func L(_ message: LocalizedMessage) -> String { Localization.render(message) }

enum Localization {
    struct Entry: Decodable, Sendable {
        let zh: String
        let en: String
    }
    static let messages: [String: Entry] = {
        guard let url = Bundle.module.url(forResource: "messages", withExtension: "json", subdirectory: "Localization"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            assertionFailure("Missing bundled localization catalog")
            return [:]
        }
        return catalog
    }()
    private static let bySource = Dictionary(uniqueKeysWithValues: messages.values.map { ($0.zh, $0.en) })
    private static let placeholders = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
    private static let state = LanguageState()

    private final class LanguageState: @unchecked Sendable {
        let lock = NSLock()
        var language = UserDefaults.standard.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .chinese
    }
    static var language: AppLanguage {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.language
    }
    static func setLanguage(_ language: AppLanguage) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.language = language
    }
    static func render(_ message: LocalizedMessage, language: AppLanguage? = nil) -> String {
        let template = (language ?? self.language) == .english ? bySource[message.template] ?? message.template : message.template
        // Replace in reverse order so placeholder-like text inside arguments is literal.
        let rendered = NSMutableString(string: template)
        for match in placeholders.matches(in: template, range: NSRange(location: 0, length: (template as NSString).length)).reversed() {
            guard let index = Int((template as NSString).substring(with: match.range(at: 1))),
                  message.arguments.indices.contains(index) else { continue }
            rendered.replaceCharacters(in: match.range, with: message.arguments[index])
        }
        return rendered as String
    }
}

struct LanguageMenu: View {
    @ObservedObject private var preferences = LanguagePreferences.shared
    var body: some View {
        Menu {
            Picker(L("界面语言"), selection: $preferences.language) {
                ForEach(AppLanguage.allCases) { language in Text(language.title).tag(language) }
            }.pickerStyle(.inline)
        } label: {
            Image(systemName: "globe").font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().pointingHandCursor()
            .help(L("切换语言")).accessibilityLabel(L("切换语言"))
    }
}
