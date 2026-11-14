import AppKit
import ApplicationServices
// axbench <pid> x y w hTall hShort durMs reps pauseMs [hz] [mode]
// Animates the first standard window of <pid> between hTall and hShort (top edge fixed), the way the engine does,
// and prints the duration of every AX step. mode: "size" (default) or "frame" (position+size each step).
setvbuf(stdout, nil, _IOLBF, 0)
let a = CommandLine.arguments
let pid = pid_t(a[1])!
let x = Double(a[2])!, y = Double(a[3])!, w = Double(a[4])!, hT = Double(a[5])!, hS = Double(a[6])!
let dur = Double(a[7])! / 1000, reps = Int(a[8])!, pause = Double(a[9])! / 1000
let hz = a.count > 10 ? Double(a[10])! : 120
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 1)
var v: CFTypeRef?
AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v)
guard let win = (v as? [AXUIElement])?.first(where: { e in
    var s: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXSubroleAttribute as CFString, &s); return (s as? String) == kAXStandardWindowSubrole as String
}) else { print("no window"); exit(1) }
func setSize(_ s: CGSize) { var s = s; AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!) }
func setPos(_ p: CGPoint) { var p = p; AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!) }
setPos(CGPoint(x: x, y: y)); setSize(CGSize(width: w, height: hT)); usleep(500_000)
var cur = hT
// WATCH=1: instead of a fixed rhythm, shrink when the Dock's AXList jumps onto the window's display, grow when it leaves.
let watch = ProcessInfo.processInfo.environment["WATCH"] == "1"
let dockApp = AXUIElementCreateApplication(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first!.processIdentifier)
func dockOnMyDisplay() -> Bool {
    var k: CFTypeRef?; AXUIElementCopyAttributeValue(dockApp, kAXChildrenAttribute as CFString, &k)
    for e in (k as? [AXUIElement]) ?? [] {
        var r: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &r)
        guard (r as? String) == "AXList" else { continue }
        var p: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &p)
        var pt = CGPoint.zero; AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        return (pt.x < 1920) == (x < 1920)
    }
    return false
}
var r = -1
while r + 1 < reps {
    if watch {
        let want = dockOnMyDisplay() ? hS : hT
        if want == cur { usleep(16_000); continue }
        if let d = ProcessInfo.processInfo.environment["DELAYMS"], want == hS { usleep(useconds_t(Double(d)! * 1000)) }
    }
    r += 1
    let from = cur, to = (cur == hT) ? hS : hT
    let start = CFAbsoluteTimeGetCurrent()
    var ends: [Double] = []
    var steps: [Double] = [], last = from
    while true {
        let fs = CFAbsoluteTimeGetCurrent(); let t = (fs - start) / dur
        if t >= 1 { break }
        let e = 1 - pow(1 - t, 3)
        let h = (from + (to - from) * e).rounded()
        if h != last { setSize(CGSize(width: w, height: h)); last = h; steps.append((CFAbsoluteTimeGetCurrent() - fs) * 1000); ends.append((CFAbsoluteTimeGetCurrent() - start) * 1000) }
        let spent = CFAbsoluteTimeGetCurrent() - fs
        if spent < 1 / hz { usleep(useconds_t((1 / hz - spent) * 1e6)) }
    }
    setSize(CGSize(width: w, height: to)); cur = to
    let slow = steps.enumerated().filter { $0.element > 30 }.map { "#\($0.offset)=\(Int($0.element))ms(ends@\(Int(ends[$0.offset])))" }
    print(String(format: "%2d %@ %3d steps avg %5.1f max %5.1f  slow: %@", r, to < from ? "shrink" : "grow  ", steps.count,
                 steps.reduce(0, +) / Double(max(steps.count, 1)), steps.max() ?? 0, slow.joined(separator: " ")))
    if !watch { usleep(useconds_t(pause * 1e6)) }
}
