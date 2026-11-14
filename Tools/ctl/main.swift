import AppKit
import ApplicationServices
// ctl: drives and inspects test windows (titles starting with "T") and the Dock, for edge-case scenarios.
//   ctl state [label]            one-line snapshot + invariant check (exit 1 if violated)
//   ctl fs <title> on|off        native full screen via AX
//   ctl min <title> on|off       minimize / restore
//   ctl frame <title> x y w h    set frame (CG coords)
//   ctl raise <title>            raise + activate the window's app
setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
func f(_ r: CGRect) -> String { String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height) }
func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt); AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}
struct Disp { let id: CGDirectDisplayID; let frame: CGRect; let visible: CGRect; var inset: CGFloat { frame.maxY - visible.maxY } }
func displays() -> [Disp] {
    let ph = NSScreen.screens.first!.frame.maxY
    return NSScreen.screens.map { s in
        let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
        let fr = s.frame, v = s.visibleFrame
        return Disp(id: id, frame: CGRect(x: fr.minX, y: ph - fr.maxY, width: fr.width, height: fr.height),
                    visible: CGRect(x: v.minX, y: ph - v.maxY, width: v.width, height: v.height))
    }
}
func disp(for r: CGRect, _ ds: [Disp]) -> Disp? { ds.max { $0.frame.intersection(r).width * $0.frame.intersection(r).height < $1.frame.intersection(r).width * $1.frame.intersection(r).height } }
// Test windows: every regular app's windows whose title starts with "T" followed by a digit
func testWindows() -> [(title: String, el: AXUIElement, pid: pid_t)] {
    var out: [(String, AXUIElement, pid_t)] = []
    for app in NSWorkspace.shared.runningApplications where app.localizedName == "testwin" {
        let ax = AXUIElementCreateApplication(app.processIdentifier); AXUIElementSetMessagingTimeout(ax, 0.5)
        for w in (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            if let t = attr(w, kAXTitleAttribute) as? String, t.hasPrefix("DDS-T") { out.append((t, w, app.processIdentifier)) }
        }
    }
    return out.sorted { $0.0 < $1.0 }
}
func dockList() -> CGRect? {
    let d = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first!
    let ax = AXUIElementCreateApplication(d.processIdentifier); AXUIElementSetMessagingTimeout(ax, 0.3)
    for k in (attr(ax, kAXChildrenAttribute) as? [AXUIElement]) ?? [] where (attr(k, kAXRoleAttribute) as? String) == "AXList" { return frame(k) }
    return nil
}
func cgDockVisible(on d: Disp) -> Bool {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    return list.contains { w in
        (w[kCGWindowOwnerName as String] as? String) == "Dock" && (w[kCGWindowLayer as String] as? Int) == 20 &&
        CGRect(dictionaryRepresentation: w[kCGWindowBounds as String] as! CFDictionary).map { d.frame.contains(CGPoint(x: $0.midX, y: $0.midY)) } == true
    }
}
func fullScreenDisplays(_ ds: [Disp]) -> Set<CGDirectDisplayID> {
    // any on-screen layer-0 window exactly covering a display = a full-screen Space is showing there
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    var out = Set<CGDirectDisplayID>()
    for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
        if let b = CGRect(dictionaryRepresentation: w[kCGWindowBounds as String] as! CFDictionary) {
            for d in ds where abs(b.minX - d.frame.minX) < 1 && abs(b.minY - d.frame.minY) < 1 && abs(b.width - d.frame.width) < 1 && abs(b.height - d.frame.height) < 1 { out.insert(d.id) }
        }
    }
    return out
}
func window(_ title: String) -> AXUIElement? { testWindows().first { $0.title == title }?.el }
func setB(_ w: AXUIElement, _ a: String, _ v: Bool) { AXUIElementSetAttributeValue(w, a as CFString, (v ? kCFBooleanTrue : kCFBooleanFalse)!) }

switch args.first ?? "state" {
case "fs": setB(window(args[1])!, "AXFullScreen", args[2] == "on")
case "min": setB(window(args[1])!, kAXMinimizedAttribute, args[2] == "on")
case "raise":
    let w = window(args[1])!; AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    if let t = testWindows().first(where: { $0.title == args[1] }) { NSRunningApplication(processIdentifier: t.pid)?.activate() }
case "frame":
    let w = window(args[1])!; let v = args[2...5].map { Double($0)! }
    var s = CGSize(width: v[2], height: v[3]), p = CGPoint(x: v[0], y: v[1])
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)
default:
    let label = args.count > 1 ? args[1] : ""
    let ds = displays()
    let autohide = (CFPreferencesCopyAppValue("autohide" as CFString, "com.apple.dock" as CFString) as? Bool) ?? false
    let list = dockList()
    let dockDisp = list.flatMap { l in ds.first { $0.frame.contains(CGPoint(x: l.midX, y: l.minY - 1)) } }
    let shown = list.map { l in dockDisp.map { $0.frame.insetBy(dx: -2, dy: -2).contains(l) } ?? false } ?? false
    let fsd = fullScreenDisplays(ds)
    var out: [String] = [], bad: [String] = [], notes: [String] = []
    for d in ds { out.append("d\(d.id):R=\(Int(d.inset))\(fsd.contains(d.id) ? ",FS" : "")\(dockDisp?.id == d.id ? ",Dock\(shown ? "" : "(hidden)")" : "")") }
    let reserved = ds.filter { $0.inset > 8 }
    if !autohide {
        if reserved.count > 1 { notes.append("2 displays reserve Dock space") }
        if let r = reserved.first, let dd = dockDisp, r.id != dd.id { notes.append("space reserved on d\(r.id) but Dock is on d\(dd.id)") }
        if reserved.isEmpty, let dd = dockDisp, !fsd.contains(dd.id), shown { notes.append("Dock shown on d\(dd.id) but nothing reserved") }
    }
    for t in testWindows() {
        let minimized = (attr(t.el, kAXMinimizedAttribute) as? Bool) == true, fs = (attr(t.el, "AXFullScreen") as? Bool) == true
        guard let r = frame(t.el) else { continue }
        var s = "\(t.title)\(f(r))"; if minimized { s += "min" }; if fs { s += "FS" }
        out.append(s)
        guard !minimized, !fs, let d = disp(for: r, ds) else { continue }
        // a "tall" test window (was glued to the bottom) must end at the usable bottom: no Dock overlap, no empty strip
        if r.height > 600 {
            let dockOver = dockDisp?.id == d.id && shown && !fsd.contains(d.id)
            let usableBottom = dockOver ? d.frame.maxY - 85 : d.frame.maxY
            if dockOver && r.maxY > d.visible.maxY + 2 && d.inset > 8 { bad.append("\(t.title) under the Dock") }
            if dockOver && d.inset <= 8 && r.maxY > usableBottom + 2 { bad.append("\(t.title) under the (unreserved) Dock") }
            if !dockOver && r.maxY < d.frame.maxY - 2 && r.maxY >= d.frame.maxY - 100 { bad.append("\(t.title) leaves a strip at the bottom") }
        }
    }
    print((bad.isEmpty ? "OK  " : "BAD ") + label + "  " + out.joined(separator: " ") + (bad.isEmpty ? "" : "  ⚠ " + bad.joined(separator: "; "))
          + (notes.isEmpty ? "" : "  [macOS: " + notes.joined(separator: "; ") + "]"))
    exit(bad.isEmpty ? 0 : 1)
}
