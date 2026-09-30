// The SMAppService half of "Launch at login". The decision about what to do
// lives in LoginItemPolicy, which Core can test.

import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Applies `LoginItemPolicy` once at launch and returns the intent to store.
    ///
    /// A failed re-registration keeps the intent rather than clearing it: the
    /// user still wants the app to start at login, and forgetting that is the
    /// bug this exists to prevent. The next launch tries again.
    static func reconcile(storedIntent: Bool?) -> Bool {
        switch LoginItemPolicy.action(storedIntent: storedIntent, systemEnabled: isEnabled) {
        case .nothingToDo:
            return storedIntent ?? isEnabled
        case .adoptSystemState(let enabled):
            return enabled
        case .register:
            Log.write("login item was not registered; registering again")
            setEnabled(true)
            return true
        case .unregister:
            Log.write("login item was registered against the setting; removing it")
            setEnabled(false)
            return false
        }
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            Log.write("login item toggle failed: \(Sanitize.oneLine(error.localizedDescription))")
            return false
        }
    }
}
