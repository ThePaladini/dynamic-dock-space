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
    /// The Dock is shown on `screenID` (autohide off) but macOS reserved no space for it — seen after leaving a
    /// full-screen Space the Dock was pulled onto. The system may stay like this until something else changes.
    var shownUnreserved = false
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
        var list: CGRect?
        if useAX, let f = axListFrame() { list = f; screen = screenFromAX(f, edge: edge, screens); source = "AX" }
        if screen == nil, let s = cgDockScreen(screens) { screen = s; source = "CGWindow" }
        // Nothing reserved while the Dock does not auto-hide: either the system is mid-transition (acting now could
        // expand windows wrongly), or the Dock now belongs to a display showing a full-screen Space — pushing the
        // pointer against the bottom of a full-screen video moves the Dock there, where it stays hidden. That second
        // case is stable: every other display has no Dock and should use its whole height.
        if !autohide, useAX, let s = screen, hasFullScreenWindow(on: s) {
            return DockState(edge: edge, autohide: autohide, screenID: s.id, reservation: 0, source: source + " (full-screen display)", stable: true)
        }
        var st = DockState(edge: edge, autohide: autohide, screenID: screen?.id, reservation: 0, source: source, stable: autohide)
        // The icon strip lies inside the display (a hidden Dock parks it past the edge).
        if !autohide, let s = screen, let f = list, s.frame.insetBy(dx: -2, dy: -2).contains(f) { st.shownUnreserved = true }
        return st
    }

    /// A window in native full screen (AXFullScreen) covering this display. Only consulted in the rare
    /// "nothing reserved" state, so enumerating apps here is cheap enough.
    static func hasFullScreenWindow(on s: ScreenInfo) -> Bool {
        let center = CGPoint(x: s.frame.midX, y: s.frame.midY)
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isTerminated {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.2)
            for w in AX.elements(ax, kAXWindowsAttribute) where AX.bool(w, "AXFullScreen") == true {
                if let f = AX.frame(w), f.contains(center) { return true }
            }
        }
        return false
    }
}
