// Cleaning text that came from outside: meeting titles and volume names.

import Foundation

/// Meeting titles come from calendar invitations and volume names come from
/// whatever disk was plugged in. Both end up in the log and, for the command
/// line tool, inside an AppleScript string literal. Control characters break
/// the second and forge lines in the first. Unicode line and paragraph
/// separators (U+2028, U+2029) are not control characters but still break a
/// line for anything that reads the log, so they go too.
enum Sanitize {
    private static let breaking = CharacterSet.controlCharacters.union(.newlines)

    static func oneLine(_ text: String, max: Int = 200) -> String {
        var out = String()
        out.reserveCapacity(min(text.count, max))
        for scalar in text.unicodeScalars {
            if out.count >= max { out += "…"; break }
            out.append(breaking.contains(scalar) ? " " : Character(scalar))
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
