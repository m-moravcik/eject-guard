// Interface translations.
//
// English, Slovak, Czech and German. The English text lives in the source as
// the fallback argument, so a missing key or a missing .lproj degrades to
// readable English rather than to a bare key on screen. That also means the
// command line tool, which has no bundle and therefore no translations, keeps
// working unchanged.
//
// Explicit keys rather than "the English sentence is the key": a key survives
// rewording, and the four .strings files can be diffed against each other.
// LocalizationTests checks that every key used here exists in all four.
//
// Log lines are deliberately *not* translated. A log is for whoever is
// debugging, is pasted into issues, and is grepped; it stays English.

import Foundation

enum Loc {
    /// A plain string.
    static func t(_ key: String, _ fallback: String) -> String {
        Bundle.main.localizedString(forKey: key, value: fallback, table: nil)
    }

    /// A string with arguments. Also the path for plurals: a key defined in
    /// Localizable.stringsdict resolves to a format containing `%#@…@`, and the
    /// expansion of that is what needs a locale, which is why this is
    /// `String(format:locale:arguments:)` and not `String(format:)`.
    static func t(_ key: String, _ fallback: String, _ args: any CVarArg...) -> String {
        String(format: Bundle.main.localizedString(forKey: key, value: fallback, table: nil),
               locale: .current,
               arguments: args)
    }
}
