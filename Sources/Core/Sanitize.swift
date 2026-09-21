// Cleaning text that came from outside: meeting titles and volume names.

import Foundation

/// Meeting titles come from calendar invitations and volume names come from
/// whatever disk was plugged in. Both end up in the log and, for the command
/// line tool, inside an AppleScript string literal. Control characters break
/// the second and forge lines in the first.
enum Sanitize {
    static func oneLine(_ text: String, max: Int = 200) -> String {
        var out = String()
        out.reserveCapacity(min(text.count, max))
        for scalar in text.unicodeScalars {
            if out.count >= max { out += "…"; break }
            out.append(CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar))
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
