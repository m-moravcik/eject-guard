// Whether this particular build is allowed to update itself.
//
// A pure function on purpose. This is the security boundary of the updater:
// downloading and executing a binary without checking who signed it is remote
// code execution. A factory reading `Bundle.main` directly would put that
// decision somewhere no test can reach, because tests run against an ad-hoc
// signed host where every gate would answer the same way and cover nothing.
//
// The reason is returned as a value rather than a sentence. Core is compiled
// into the command line tool too, which has no bundle and therefore no
// localisation; turning a reason into words is the app's job.

import Foundation

enum UpdaterGate {
    enum Reason: Equatable, Sendable {
        /// Not signed by us: a debug or ad-hoc build must never self-update.
        case notSigned
        /// Running as a loose binary rather than an installed bundle.
        case notABundle
    }

    enum Decision: Equatable, Sendable {
        case enabled
        case disabled(reason: Reason)
    }

    /// - Parameters:
    ///   - bundleURL: the running bundle, normally `Bundle.main.bundleURL`.
    ///   - isDeveloperIDSigned: whether that bundle carries our Developer ID
    ///     signature. Passed in rather than measured here so the decision stays
    ///     testable without a signed fixture.
    static func decide(bundleURL: URL, isDeveloperIDSigned: Bool) -> Decision {
        // Signature first. Both branches disable updates, but an unsigned build
        // should say so rather than blame its location.
        guard isDeveloperIDSigned else { return .disabled(reason: .notSigned) }
        guard bundleURL.pathExtension == "app" else { return .disabled(reason: .notABundle) }
        return .enabled
    }
}
