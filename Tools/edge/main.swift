import AppKit
import ApplicationServices
// edge <secs>: logs when the pointer first touches a display's bottom edge, when the Dock's AXList jumps there,
// and when that display's visibleFrame changes (NSScreen), to measure the lead time available before the move.
setvbuf(stdout, nil, _IOLBF, 0)
let secs = Double(CommandLine.arguments[1])!
let dockApp = AXUIElementCreateApplication(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first!.processIdentifier)
AXUIElementSetMessagingTimeout(dockApp, 0.3)
func listX() -> CGFloat? {
    var k: CFTypeRef?; AXUIElementCopyAttributeValue(dockApp, kAXChildrenAttribute as CFString, &k)
    for e in (k as? [AXUIElement]) ?? [] {
        var r: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &r)
        guard (r as? String) == "AXList" else { continue }
        var p: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &p)
        var pt = CGPoint.zero; AXValueGetValue(p as! AXValue, .cgPoint, &pt); return pt.x
    }
    return nil
}
let start = CFAbsoluteTimeGetCurrent()
func now() -> String { String(format: "%7.3f", CFAbsoluteTimeGetCurrent() - start) }
var lastSide = (listX() ?? 0) < 1920 ? "L" : "R"
var touching = false
var lastVis = NSScreen.screens.map { $0.visibleFrame.minY }
let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 240, repeats: true) { _ in
    if CFAbsoluteTimeGetCurrent() - start > secs { exit(0) }
    let m = NSEvent.mouseLocation   // cocoa: y = 0 at the bottom of the primary display
    let atEdge = m.y <= 1
    let side = m.x < 1920 ? "L" : "R"
    if atEdge && !touching && side != lastSide { print(now(), "pointer touches bottom of", side) }
    touching = atEdge
    if let x = listX() { let s = x < 1920 ? "L" : "R"; if s != lastSide { print(now(), "Dock AXList jumps to", s); lastSide = s } }
    let vis = NSScreen.screens.map { $0.visibleFrame.minY }
    if vis != lastVis { print(now(), "visibleFrame changed", vis); lastVis = vis }
}
RunLoop.main.add(t, forMode: .common)
NSApplication.shared.setActivationPolicy(.prohibited)
NSApplication.shared.run()
