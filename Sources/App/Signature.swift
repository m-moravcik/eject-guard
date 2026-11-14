// Who signed the running app. Used by the updater gate and by Copy
// diagnostics; on its own file so the preview harness, which has no Sparkle,
// can compile the Settings window that reports it.

import Foundation
import Security

/// True when the bundle carries a Developer ID Application signature from our
/// team.
///
/// Sparkle's EdDSA signature on the downloaded archive is a separate and
/// equally necessary check: this one says *we* are the thing running, that one
/// says the thing we fetched came from us. Neither substitutes for the other.
func isDeveloperIDSigned(bundleURL: URL) -> Bool {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
          let staticCode
    else { return false }

    var requirement: SecRequirement?
    let text = "anchor apple generic and certificate leaf[subject.OU] = \"7TM9VA58W5\"" as CFString
    guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess,
          let requirement
    else { return false }

    return SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess
}
