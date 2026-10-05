import Foundation

/// The languages the interface is available in.
public enum Language: String, CaseIterable, Sendable {
    case polish = "pl"
    case english = "en"

    public var locale: Locale { Locale(identifier: rawValue) }

    /// - Parameters:
    ///   - preference: a language code to force, or anything else (e.g. "auto") to follow the system.
    ///   - preferredLanguages: the system's language list, most preferred first.
    /// - Returns: Polish on a Polish system, English on any other.
    public static func resolve(preference: String?, preferredLanguages: [String]) -> Language {
        if let preference, let forced = Language(rawValue: preference) { return forced }
        guard let first = preferredLanguages.first?.lowercased() else { return .english }
        return first == "pl" || first.hasPrefix("pl-") || first.hasPrefix("pl_") ? .polish : .english
    }

    /// The user's system-wide language list, ignoring any per-app override.
    public static var systemLanguages: [String] {
        let value = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                           kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return value as? [String] ?? Locale.preferredLanguages
    }
}

public enum PolishGrammar {
    /// The noun form Polish uses after `count`: 1 rdzeń, 2-4 rdzenie (but 12-14 rdzeni), otherwise rdzeni.
    public static func form(for count: Int, one: String, few: String, many: String) -> String {
        if count == 1 { return one }
        let lastDigit = count % 10, lastTwo = count % 100
        return (2...4).contains(lastDigit) && !(12...14).contains(lastTwo) ? few : many
    }
}
