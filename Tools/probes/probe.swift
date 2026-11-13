import AppKit
import ApplicationServices

func r(_ x: CGRect) -> String { String(format: "(%.0f,%.0f %.0fx%.0f)", x.origin.x, x.origin.y, x.width, x.height) }
let primaryH = NSScreen.screens.first!.frame.height
func flip(_ f: CGRect) -> CGRect { CGRect(x: f.minX, y: primaryH - f.maxY, width: f.width, height: f.height) } // Cocoa -> CG (top-left)

print("AXIsProcessTrusted:", AXIsProcessTrusted())
for s in NSScreen.screens {
    let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
    let f = flip(s.frame), v = flip(s.visibleFrame)
    print("screen \(id) \(s.localizedName) frameCG=\(r(f)) visibleCG=\(r(v)) insets top=\(v.minY-f.minY) bottom=\(f.maxY-v.maxY) left=\(v.minX-f.minX) right=\(f.maxX-v.maxX)")
}
print("-- CG windows owned by Dock (on-screen + offscreen)")
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerName as String] as? String) == "Dock" {
    let b = CGRect(dictionaryRepresentation: w[kCGWindowBounds as String] as! CFDictionary)!
    print("  layer=\(w[kCGWindowLayer as String]!) name=\(w[kCGWindowName as String] ?? "-") onscreen=\(w[kCGWindowIsOnscreen as String] ?? false) bounds=\(r(b))")
}
if let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
    let ax = AXUIElementCreateApplication(dock.processIdentifier)
    var kids: CFTypeRef?
    AXUIElementCopyAttributeValue(ax, kAXChildrenAttribute as CFString, &kids)
    for k in (kids as? [AXUIElement]) ?? [] {
        var role: CFTypeRef?, pos: CFTypeRef?, size: CFTypeRef?
        AXUIElementCopyAttributeValue(k, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(k, kAXPositionAttribute as CFString, &pos)
        AXUIElementCopyAttributeValue(k, kAXSizeAttribute as CFString, &size)
        var p = CGPoint.zero, z = CGSize.zero
        if let pos { AXValueGetValue(pos as! AXValue, .cgPoint, &p) }
        if let size { AXValueGetValue(size as! AXValue, .cgSize, &z) }
        print("  AX child role=\(role ?? "-" as CFTypeRef) frame=\(r(CGRect(origin: p, size: z)))")
    }
}
