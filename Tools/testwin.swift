import AppKit
// testwin "x,y,w,h" ...   (CG coords, top-left origin). Logs every frame change of its windows; exits after N s (env SECS).
setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let ph = NSScreen.screens.first!.frame.maxY
func toCG(_ r: NSRect) -> String { String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, ph - r.maxY, r.width, r.height) }
var wins: [NSWindow] = []
for (i, a) in CommandLine.arguments.dropFirst().enumerated() {
    let parts = a.split(separator: ",")
    let minimize = parts.last == "m"
    let v = parts.prefix(4).map { CGFloat(Double($0)!) }
    let r = NSRect(x: v[0], y: ph - v[1] - v[3], width: v[2], height: v[3])
    let w = NSWindow(contentRect: .zero, styleMask: [.titled, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false)
    w.title = "T\(i)"; w.isReleasedWhenClosed = false
    w.setFrame(r, display: true)
    w.orderFront(nil)
    wins.append(w)
    if minimize { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { w.miniaturize(nil) } }
    print("T\(i) init \(toCG(w.frame))")
    for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
        NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { _ in print(String(format: "%.3f", CFAbsoluteTimeGetCurrent().truncatingRemainder(dividingBy: 1000)), "T\(i) now  \(toCG(w.frame))") }
    }
}
// DELAY=ms simulates an app that takes that long to re-layout on each resize (like Chrome/Finder).
let delay = Double(ProcessInfo.processInfo.environment["DELAY"] ?? "0")!
if delay > 0 {
    for w in wins { NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: w, queue: .main) { _ in usleep(useconds_t(delay * 1000)) } }
}
// FS="2,8" toggles native full screen of T0 at those seconds.
if let fs = ProcessInfo.processInfo.environment["FS"], let w = wins.first {
    w.collectionBehavior.insert(.fullScreenPrimary)
    for t in fs.split(separator: ",").map({ Double($0)! }) {
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { print(String(format: "%.3f", CFAbsoluteTimeGetCurrent().truncatingRemainder(dividingBy: 1000)), "T0 toggleFullScreen"); w.toggleFullScreen(nil) }
    }
}
let secs = Double(ProcessInfo.processInfo.environment["SECS"] ?? "60")!
DispatchQueue.main.asyncAfter(deadline: .now() + secs) { for (i, w) in wins.enumerated() { print("T\(i) final \(toCG(w.frame))") }; exit(0) }
app.run()
