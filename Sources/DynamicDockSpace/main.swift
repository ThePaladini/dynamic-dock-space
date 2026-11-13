import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = Settings()
    lazy var engine = Engine(settings: settings)
    var menu: StatusMenu!
    var trustTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        let args = CommandLine.arguments
        Log.verbose = args.contains("--verbose")
        if let i = args.firstIndex(of: "--only"), i + 1 < args.count { engine.onlyAppName = args[i + 1] }
        engine.dryRun = args.contains("--dry-run")
        if let i = args.firstIndex(of: "--only-title"), i + 1 < args.count { engine.onlyTitle = args[i + 1] }

        engine.detect()
        menu = StatusMenu(engine: engine, settings: settings)
        let nc = NotificationCenter.default, wnc = NSWorkspace.shared.notificationCenter
        // Fired when visibleFrame changes (Dock moves/hides/resizes), and on display connect/disconnect/arrangement.
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.engine.schedule("displays/Dock changed", after: 0.3)
            self?.engine.detect(); self?.menu.refreshIcon()   // standby state may have changed (display count)
        }
        // AX only lists windows of the visible Spaces: reconcile windows as their Space becomes active.
        wnc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.engine.schedule("Space changed", after: 0.4)
        }
        wnc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.engine.schedule("wake", after: 2)
        }
        wnc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.engine.forgetApp(a.processIdentifier) }
        }

        if AXIsProcessTrusted() {
            engine.schedule("launch", after: 0.5)
        } else {
            Permissions.explainAndRequest()
            // Light polling only while permission is missing; stops as soon as it is granted.
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                guard AXIsProcessTrusted() else { return }
                t.invalidate(); self?.trustTimer = nil
                self?.menu.refreshIcon(); self?.engine.schedule("permission granted", after: 0.2)
            }
        }
        Log.info("started; AX=\(AXIsProcessTrusted()) only=\(engine.onlyAppName ?? "-") dryRun=\(engine.dryRun)")
    }
}

// CLI: `DynamicDockSpace --status` prints what is detected and exits (no window changes).
if CommandLine.arguments.contains("--status") {
    _ = NSApplication.shared
    let screens = Screens.snapshot()
    let dock = DockDetector.detect(screens, useAX: AXIsProcessTrusted())
    print("Accessibility: \(AXIsProcessTrusted() ? "allowed" : "NOT allowed")")
    for s in screens {
        print("display \(s.id) \(s.isBuiltin ? "built-in" : s.name) frame=\(s.frame.short) visible=\(s.visible.short) inset(\(dock.edge.rawValue))=\(Int(s.inset(dock.edge)))\(s.id == dock.screenID ? "  ← Dock" : "")")
    }
    print("Dock: display=\(dock.screenID.map(String.init) ?? "?") edge=\(dock.edge.rawValue) autohide=\(dock.autohide) reservation=\(Int(dock.reservation)) source=\(dock.source) stable=\(dock.stable)")
    if let f = DockDetector.axListFrame() { print("Dock AXList: \(f.short)") }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
