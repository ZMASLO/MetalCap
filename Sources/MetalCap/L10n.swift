import Foundation
import MetalCapCore

enum L10n {
    static let preferenceKey = "language"

    /// "auto", "pl" or "en".
    static var preference: String {
        UserDefaults.standard.string(forKey: preferenceKey) ?? "auto"
    }

    /// The language the interface is shown in. `--lang pl|en` on the command line forces one for this run.
    static var language: Language = {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--lang"), index + 1 < arguments.count,
           let forced = Language(rawValue: arguments[index + 1]) {
            return forced
        }
        return Language.resolve(preference: preference, preferredLanguages: Language.systemLanguages)
    }()
}

/// Picks the text for the current interface language.
func tr(_ polish: String, _ english: String) -> String {
    L10n.language == .polish ? polish : english
}
