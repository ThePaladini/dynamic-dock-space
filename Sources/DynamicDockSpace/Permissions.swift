import AppKit
import ApplicationServices

enum Permissions {
    static func request() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Explain before prompting, so the user knows exactly why the permission is needed.
    static func explainAndRequest() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = L("Dynamic Dock Space needs Accessibility permission")
        a.informativeText = L("permission.explanation")
        a.addButton(withTitle: L("Open System Settings"))
        a.addButton(withTitle: L("Not Now"))
        if a.runModal() == .alertFirstButtonReturn { request() }
    }
}
