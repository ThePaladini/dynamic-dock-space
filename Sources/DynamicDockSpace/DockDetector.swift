import AppKit
import ApplicationServices

enum DockEdge: String {
    case bottom, left, right
    var label: String { switch self { case .bottom: return L("bottom"); case .left: return L("left"); case .right: return L("right") } }
}

struct DockState: Equatable {
    var edge: DockEdge
    var autohide: Bool
    /// Display that currently owns the Dock (also known while it is hidden), if identified.
    var screenID: CGDirectDisplayID?
    /// Space the system reserves for the Dock on that display (0 when hidden).
    var reservation: CGFloat
    /// How the screen was identified.
    var source: String
    /// False while the system is in an inconsistent/transitional state (Dock visible but nothing reserved).
    var stable: Bool
}

enum DockDetector {
    static let reserveThreshold: CGFloat = 8

    static func readPrefs() -> (edge: DockEdge, autohide: Bool) {
        let domain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(domain)
        let o = CFPreferencesCopyAppValue("orientation" as CFString, domain) as? String
        let a = (CFPreferencesCopyAppValue("autohide" as CFString, domain) as? NSNumber)?.boolValue ?? false
        return (DockEdge(rawValue: o ?? "bottom") ?? .bottom, a)
    }

    /// Frame of the Dock's AXList (icons strip). Present even when the Dock is auto-hidden: it then sits just
    /// beyond the edge of its display. Requires Accessibility permission.
    static func axListFrame() -> CGRect? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)
        for k in AX.elements(app, kAXChildrenAttribute) where AX.string(k, kAXRoleAttribute) == "AXList" {
            return AX.frame(k)
        }
        return nil
    }

    /// The Dock owns a layer-20 window covering the display it is on while it is shown. No permission needed.
    static func cgDockScreen(_ screens: [ScreenInfo]) -> ScreenInfo? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowOwnerName as String] as? String) == "Dock"
            && (w[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.dockWindow)) {
            if let d = w[kCGWindowBounds as String], let b = CGRect(dictionaryRepresentation: d as! CFDictionary) {
                return Screens.screen(for: b, in: screens)
            }
        }
        return nil
    }

    static func screenFromAX(_ f: CGRect, edge: DockEdge, _ screens: [ScreenInfo]) -> ScreenInfo? {
        // Probe a point just inside the display edge the strip is attached to (works shown or hidden).
        let p: CGPoint
        switch edge {
        case .bottom: p = CGPoint(x: f.midX, y: f.minY - 1)
        case .left: p = CGPoint(x: f.maxX + 1, y: f.midY)
        case .right: p = CGPoint(x: f.minX - 1, y: f.midY)
        }
        return Screens.screen(containing: p, in: screens) ?? Screens.screen(for: f, in: screens)
    }

    static func detect(_ screens: [ScreenInfo], useAX: Bool) -> DockState {
        let (edge, autohide) = readPrefs()
        let reserved = screens.filter { $0.inset(edge) > reserveThreshold }
        if let s = reserved.max(by: { $0.inset(edge) < $1.inset(edge) }) {
            return DockState(edge: edge, autohide: autohide, screenID: s.id, reservation: s.inset(edge), source: "visibleFrame", stable: reserved.count == 1)
        }
        var screen: ScreenInfo?
        var source = "?"
        if useAX, let f = axListFrame() { screen = screenFromAX(f, edge: edge, screens); source = "AX" }
        if screen == nil, let s = cgDockScreen(screens) { screen = s; source = "CGWindow" }
        // Nothing reserved: legitimate only when the Dock auto-hides. Otherwise the system is mid-transition
        // (or a full-screen Space is showing on the Dock's display); acting now could expand windows wrongly.
        return DockState(edge: edge, autohide: autohide, screenID: screen?.id, reservation: 0, source: source, stable: autohide)
    }
}
