import AppKit
import ApplicationServices
setvbuf(stdout, nil, _IOLBF, 0)
func r(_ x: CGRect) -> String { String(format: "(%.0f,%.0f %.0fx%.0f)", x.origin.x, x.origin.y, x.width, x.height) }
func snapshot() -> String {
    var out: [String] = []
    let primaryH = NSScreen.screens.first?.frame.height ?? 0
    for s in NSScreen.screens {
        let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
        let f = s.frame, v = s.visibleFrame
        out.append("s\(id):b=\(Int(v.minY-f.minY)),t=\(Int(f.maxY-v.maxY)),l=\(Int(v.minX-f.minX)),r=\(Int(f.maxX-v.maxX))")
    }
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
    for w in list where (w[kCGWindowOwnerName as String] as? String) == "Dock" && (w[kCGWindowLayer as String] as? Int) == 20 {
        out.append("cgDock=" + r(CGRect(dictionaryRepresentation: w[kCGWindowBounds as String] as! CFDictionary)!))
    }
    if let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
        let ax = AXUIElementCreateApplication(dock.processIdentifier)
        var kids: CFTypeRef?
        AXUIElementCopyAttributeValue(ax, kAXChildrenAttribute as CFString, &kids)
        for k in (kids as? [AXUIElement]) ?? [] {
            var role: CFTypeRef?; AXUIElementCopyAttributeValue(k, kAXRoleAttribute as CFString, &role)
            guard (role as? String) == "AXList" else { continue }
            var pos: CFTypeRef?, size: CFTypeRef?
            AXUIElementCopyAttributeValue(k, kAXPositionAttribute as CFString, &pos)
            AXUIElementCopyAttributeValue(k, kAXSizeAttribute as CFString, &size)
            var p = CGPoint.zero, z = CGSize.zero
            if let pos { AXValueGetValue(pos as! AXValue, .cgPoint, &p) }
            if let size { AXValueGetValue(size as! AXValue, .cgSize, &z) }
            out.append("axList=" + r(CGRect(origin: p, size: z)))
        }
    }
    _ = primaryH
    return out.joined(separator: " ")
}
let start = Date()
var last = ""
func log(_ tag: String) {
    let s = snapshot()
    if s != last || tag != "poll" { print(String(format: "%7.2f", Date().timeIntervalSince(start)), tag, s); last = s }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in log("NOTIF screenParams") }
Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in log("poll") }
log("start")
DispatchQueue.main.asyncAfter(deadline: .now() + Double(CommandLine.arguments.dropFirst().first ?? "60")!) { exit(0) }
app.run()
