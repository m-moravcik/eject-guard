// What to do at launch when "Launch at login" as the user set it and the
// system's registration disagree.
//
// The registration can drop without anyone touching the toggle: a bundle that
// is replaced or moved invalidates it. Reading only the system's state, the
// toggle then quietly shows off and nobody notices the app no longer starts.
// So the intent is stored on its own and the registration is repaired from it.
//
// Pure, and in Core, so the decision is testable without SMAppService - the
// same split VibeRes uses in its LoginItem.

import Foundation

enum LoginItemPolicy {
    enum Action: Equatable, Sendable {
        case nothingToDo
        case register
        case unregister
        /// No recorded intent yet: take the system's word for it rather than
        /// flipping the setting under an existing user.
        case adoptSystemState(enabled: Bool)
    }

    static func action(storedIntent: Bool?, systemEnabled: Bool) -> Action {
        guard let storedIntent else { return .adoptSystemState(enabled: systemEnabled) }
        if storedIntent == systemEnabled { return .nothingToDo }
        return storedIntent ? .register : .unregister
    }
}
