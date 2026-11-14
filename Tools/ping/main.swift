import AppKit
import ApplicationServices
// ping <pid> <secs>: reads the size of the app's first window every ~10 ms; prints reads slower than 20 ms with the
// time they started, plus pointer-at-bottom and Dock AXList jumps, all on the same clock.
setvbuf(stdout, nil, _IOLBF, 0)
let pid = pid_t(CommandLine.arguments[1])!, secs = Double(CommandLine.arguments[2])!
let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app, 2)
var v: CFTypeRef?; AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v)
let win = (v as! [AXUIElement])[0]
let dockApp = AXUIElementCreateApplication(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first!.processIdentifier)
func listLeft() -> Bool? {
    var k: CFTypeRef?; AXUIElementCopyAttributeValue(dockApp, kAXChildrenAttribute as CFString, &k)
    for e in (k as? [AXUIElement]) ?? [] {
        var r: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &r)
        guard (r as? String) == "AXList" else { continue }
        var p: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &p)
        var pt = CGPoint.zero; AXValueGetValue(p as! AXValue, .cgPoint, &pt); return pt.x < 1920
    }
    return nil
}
let start = CFAbsoluteTimeGetCurrent()
func now() -> Double { (CFAbsoluteTimeGetCurrent() - start) * 1000 }
var side = listLeft(); var atEdge = false
// Dock + pointer watcher on its own thread so a frozen Chrome does not delay it
Thread.detachNewThread {
    while now() < secs * 1000 {
        let m = CGEvent(source: nil)!.location
        let e = m.y >= 1079
        if e && !atEdge { print(String(format: "%7.0f pointer at bottom (%@)", now(), m.x < 1920 ? "L" : "R")) }
        atEdge = e
        let s = listLeft(); if s != side { print(String(format: "%7.0f Dock jumps %@", now(), s == true ? "L" : "R")); side = s }
        usleep(4000)
    }
}
while now() < secs * 1000 {
    let t = now()
    var sz: CFTypeRef?; AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sz)
    let d = now() - t
    if d > 20 { print(String(format: "%7.0f   Chrome read took %.0f ms", t, d)) }
    usleep(10_000)
}
