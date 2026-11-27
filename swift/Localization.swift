import Foundation

/// Looks a French source string up in the app's Localizable.strings.
/// French is the development language: a missing translation falls back to the French text.
func tr(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// Same, for strings with `%d` / `%@` placeholders.
func tr(_ key: String, _ args: CVarArg...) -> String {
    String(format: tr(key), locale: Locale.current, arguments: args)
}

enum FlowLanguage {
    /// Languages the engine can translate its own messages into.
    private static let engineLanguages: Set<String> = ["en", "zh", "ja", "ko", "es", "de", "ru"]

    /// Tells the engine which language to use for its error messages (it has no French: English then).
    static func configureEngine() {
        let preferred = Bundle.main.preferredLocalizations.first ?? "en"
        let code = String(preferred.prefix(2))
        UserDefaults.standard.set(engineLanguages.contains(code) ? code : "en", forKey: "language")
    }
}
