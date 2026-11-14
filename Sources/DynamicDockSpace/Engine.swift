import AppKit
import ApplicationServices

/// Event-driven reconciler. Everything that touches AX runs on `queue`; scheduling and NSScreen reads on main.
final class Engine {
    struct WinKey: Hashable {
        let el: AXUIElement
        func hash(into h: inout Hasher) { h.combine(CFHash(el)) }
        static func == (a: WinKey, b: WinKey) -> Bool { CFEqual(a.el, b.el) }
    }
    struct AppRef { let pid: pid_t; let name: String }
    struct Context {
        let screens: [ScreenInfo]; let dock: DockState; let lastReservation: CGFloat?; let extendGlued: Bool; let scope: Planner.Scope; let apps: [AppRef]
        let pre: PreSnapshot?; let isVerification: Bool; let animate: Bool
        var onlyScreen: CGDirectDisplayID? = nil; var duration: Double = Engine.animationDuration
    }
    /// Window bounds captured just before an expected Dock move (no AX, ~1 ms).
    struct PreSnapshot { let at: Date; let windows: [(pid: pid_t, bounds: CGRect)]
        func has(_ pid: pid_t, _ r: CGRect) -> Bool { windows.contains { $0.pid == pid && $0.bounds.approx(r) } }
    }

    let settings: Settings
    /// Test hook: only touch windows of apps whose name matches.
    var onlyAppName: String?
    /// Test hook: only touch windows whose title contains this.
    var onlyTitle: String?
    var dryRun = false
    /// Called on main whenever detection runs.
    var onDetect: ((DockState, [ScreenInfo]) -> Void)?
    private(set) var lastDock: DockState?
    private(set) var lastScreens: [ScreenInfo] = []

    private let queue = DispatchQueue(label: "io.github.thepaladini.DynamicDockSpace.engine", qos: .userInitiated)
    private var records: [WinKey: Planner.Record] = [:]   // queue-confined
    private var pendingWork: DispatchWorkItem?
    /// Changes the app overrode while reacting to the same screen change; retried once by the verification pass.
    private struct Pending { let target: CGRect; let kind: Planner.Kind?; let before: CGRect; let seen: CGRect; let pid: pid_t; let screenID: CGDirectDisplayID }
    private var pending: [WinKey: Pending] = [:]            // queue-confined
    private var lastSeen: [WinKey: CGRect] = [:]          // queue-confined: frame at the end of the previous pass
    private var pre: PreSnapshot?                          // main
    private var lastPreAt = Date.distantPast
    private var unstableAttempts = 0
    private var mouseWaits = 0
    private var leftFullScreenOn: CGDirectDisplayID?        // main

    init(settings: Settings) { self.settings = settings }

    /// Debounced; safe to call often. Main thread only.
    func schedule(_ reason: String, after delay: TimeInterval = 0.5, verification: Bool = false) {
        pendingWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.fire(reason, verification: verification) }
        pendingWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// Detection only (menu refresh). Main thread.
    @discardableResult func detect() -> DockState {
        let screens = Screens.snapshot()
        let dock = DockDetector.detect(screens, useAX: AXIsProcessTrusted())
        lastDock = dock; lastScreens = screens
        updatePointerMonitor()
        onDetect?(dock, screens)
        return dock
    }

    /// Called from a global mouse-moved monitor. When the pointer touches the Dock edge of a display that does
    /// not hold the Dock, the Dock may be about to move: remember where every window is *before* apps react.
    func pointerMoved(cocoa c: NSPoint) {
        // Uses the cached snapshot (refreshed on every screen change); the primary display is first.
        guard let dock = lastDock, !dock.autohide, let primary = lastScreens.first else { return }
        let p = CGPoint(x: c.x, y: primary.frame.height - c.y)
        guard let s = lastScreens.first(where: { $0.id != dock.screenID && $0.frame.insetBy(dx: -1, dy: -1).contains(p) }),
              Self.isNearEdge(p, s, dock.edge) else { return }
        if Date().timeIntervalSince(lastPreAt) > 0.5 {
            lastPreAt = Date()
            let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
            let wins: [(pid: pid_t, bounds: CGRect)] = list.compactMap { w in
                guard (w[kCGWindowLayer as String] as? Int) == 0, let pid = w[kCGWindowOwnerPID as String] as? Int,
                      let d = w[kCGWindowBounds as String], let b = CGRect(dictionaryRepresentation: d as! CFDictionary) else { return nil }
                return (pid_t(pid), b)
            }
            pre = PreSnapshot(at: Date(), windows: wins)
        }
        startEdgeWatch(s.id, dock.edge)
    }

    static func isNearEdge(_ p: CGPoint, _ s: ScreenInfo, _ e: DockEdge) -> Bool {
        switch e {
        case .bottom: return p.y >= s.frame.maxY - 3
        case .left: return p.x <= s.frame.minX + 3
        case .right: return p.x >= s.frame.maxX - 3
        }
    }

    private var edgeWatch: Timer?
    private var pointerMonitor: Any?

    /// Global pointer watch (delivered by AppKit only with Accessibility permission; ~1 % of one core while the
    /// mouse moves, nothing when it doesn't). Installed only while it can be useful: automation on, ≥2 displays.
    func updatePointerMonitor() {
        let wanted = settings.enabled && !isStandby && lastScreens.count >= 2 && AXIsProcessTrusted()
        if wanted, pointerMonitor == nil {
            pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
                self?.pointerMoved(cocoa: NSEvent.mouseLocation)
            }
        } else if !wanted, let m = pointerMonitor {
            NSEvent.removeMonitor(m); pointerMonitor = nil
        }
    }
    private var lastPrediction = Date.distantPast

    /// "Only with more than one display" is on and a single display is connected.
    var isStandby: Bool { settings.onlyMultiMonitor && lastScreens.count < 2 }

    /// While the pointer rests on the Dock edge of a display without the Dock, watch (≤2 s, 60 Hz, one ~1 ms AX
    /// call) for the Dock starting to move there. Its AXList jumps to the new display ~200 ms before visibleFrame
    /// changes — which is what makes every app clamp its windows abruptly. Shrinking first lets us animate it.
    private func startEdgeWatch(_ target: CGDirectDisplayID, _ edge: DockEdge) {
        guard edgeWatch == nil, Date().timeIntervalSince(lastPrediction) > 2,
              settings.enabled, settings.animate, !isStandby, AXIsProcessTrusted(),
              settings.lastReservation(edge) != nil else { return }
        let started = Date()
        edgeWatch = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            func stop() { t.invalidate(); self.edgeWatch = nil }
            guard Date().timeIntervalSince(started) < 2, let primary = self.lastScreens.first,
                  let s = self.lastScreens.first(where: { $0.id == target }) else { stop(); return }
            if let f = DockDetector.axListFrame(), DockDetector.screenFromAX(f, edge: edge, self.lastScreens)?.id == target {
                stop(); self.lastPrediction = Date(); self.predictArrival(on: target); return
            }
            let c = NSEvent.mouseLocation
            if !Self.isNearEdge(CGPoint(x: c.x, y: primary.frame.height - c.y), s, edge) { stop() }
        }
    }

    /// Shrink windows on the display the Dock is arriving at, using the Dock thickness learned before.
    private func predictArrival(on target: CGDirectDisplayID) {
        guard let dock = lastDock, let R = settings.lastReservation(dock.edge),
              let s = lastScreens.first(where: { $0.id == target }), NSEvent.pressedMouseButtons == 0 else { return }
        let screens = Self.reserving(R, dock.edge, on: s, in: lastScreens)
        let predicted = DockState(edge: dock.edge, autohide: false, screenID: target, reservation: R, source: "prediction", stable: true)
        var ctx = makeContext(screens: screens, dock: predicted, verification: false)
        ctx.onlyScreen = target
        ctx.duration = 0.2
        Log.info("reconcile [prediction] Dock arriving on display \(target)")
        queue.async { self.reconcile(ctx) }
        // If the move does not complete, the regular pass (or this fallback) puts things back.
        schedule("prediction check", after: 1.0)
    }

    /// `screens` with the Dock thickness `R` taken out of display `s`'s usable area.
    static func reserving(_ R: CGFloat, _ edge: DockEdge, on s: ScreenInfo, in screens: [ScreenInfo]) -> [ScreenInfo] {
        let synth = ScreenInfo(id: s.id, name: s.name, frame: s.frame, visible: Planner.usable(s, edge, dock: R), isBuiltin: s.isBuiltin)
        return screens.map { $0.id == s.id ? synth : $0 }
    }

    private func makeContext(screens: [ScreenInfo], dock: DockState, verification: Bool) -> Context {
        let me = ProcessInfo.processInfo.processIdentifier
        let excluded = Set(settings.excluded)
        let apps = NSWorkspace.shared.runningApplications.compactMap { a -> AppRef? in
            guard a.activationPolicy == .regular, !a.isTerminated, a.processIdentifier != me else { return nil }
            if let b = a.bundleIdentifier, excluded.contains(b) { return nil }
            let name = a.localizedName ?? "pid \(a.processIdentifier)"
            if let only = onlyAppName, name != only { return nil }
            return AppRef(pid: a.processIdentifier, name: name)
        }
        let recentPre = pre.flatMap { Date().timeIntervalSince($0.at) < 8 ? $0 : nil }
        return Context(screens: screens, dock: dock, lastReservation: settings.lastReservation(dock.edge),
                       extendGlued: settings.extendGlued, scope: settings.scope, apps: apps, pre: recentPre, isVerification: verification,
                       animate: settings.animate)
    }

    private func fire(_ reason: String, verification: Bool = false) {
        let previous = lastDock
        var dock = detect()
        var screens = lastScreens
        // The Dock was on a full-screen display that is now an ordinary one: full screen was just exited there.
        if let p = previous, p.source.hasSuffix("(full-screen display)"), !dock.source.hasSuffix("(full-screen display)") {
            leftFullScreenOn = p.screenID
        }
        if dock.reservation > 0 { settings.setLastReservation(dock.reservation, dock.edge) }
        guard settings.enabled, AXIsProcessTrusted() else { return }
        guard !isStandby else { Log.info("standby: only one display connected"); return }
        // Never fight a drag/resize in progress: wait until all mouse buttons are released.
        if NSEvent.pressedMouseButtons != 0, mouseWaits < 200 {
            mouseWaits += 1; schedule(reason, after: 0.25); return
        }
        mouseWaits = 0
        if !dock.stable {
            unstableAttempts += 1
            // Normally wait a second: during an ordinary Dock move macOS reserves the space ~200 ms late. Right after
            // leaving full screen on the Dock's display it never does, so act at once.
            let justLeft = dock.screenID != nil && dock.screenID == leftFullScreenOn
            if unstableAttempts > 4 || justLeft, dock.shownUnreserved, let id = dock.screenID, let R = settings.lastReservation(dock.edge),
               let s = screens.first(where: { $0.id == id }) {
                // The Dock has been shown on this display for over a second and macOS still reserves nothing for it
                // (e.g. after leaving a full-screen Space the Dock had been pulled onto), so apps are not kept clear
                // of it. Act as if the usual thickness were reserved; once macOS catches up nothing else changes.
                Log.info("Dock shown on display \(id) but no space reserved by macOS; assuming \(Int(R)) pt")
                screens = Self.reserving(R, dock.edge, on: s, in: screens)
                dock.reservation = R; dock.stable = true; dock.source += " (assumed reservation)"
                leftFullScreenOn = nil
            } else {
                if unstableAttempts <= 12 { schedule(reason, after: 0.25) }
                else { Log.info("Dock state undetermined (\(dock)); nothing changed"); unstableAttempts = 0 }
                return
            }
        }
        unstableAttempts = 0
        if !dock.source.hasSuffix("(assumed reservation)"), !dock.source.hasSuffix("(full-screen display)") { leftFullScreenOn = nil }
        // Leaving full screen also changes the Space; if the window was still finishing its exit animation, look
        // again once it is done (the Dock is then shown on that display, often with nothing reserved).
        if reason == "Space changed", dock.source.hasSuffix("(full-screen display)") {
            DispatchQueue.main.async { self.schedule("full-screen recheck", after: 1.2) }
        }
        let ctx = makeContext(screens: screens, dock: dock, verification: verification)
        Log.info("reconcile [\(reason)] dock=\(dock.screenID.map(String.init) ?? "?") \(dock.edge.rawValue) R=\(Int(dock.reservation)) autohide=\(dock.autohide) via \(dock.source)")
        queue.async {
            let changed = self.reconcile(ctx)
            // Apps also react to the same screen change and may override us; check once more after they settle.
            if changed > 0, !verification {  // includes overridden attempts kept in `pending`
                DispatchQueue.main.async { self.schedule("verification", after: 0.8, verification: true) }
            }
        }
    }

    /// Forget everything (e.g. automation disabled).
    func clearRecords() { queue.async { self.records.removeAll() } }

    private struct Job {
        let app: AppRef; let w: AXUIElement; let key: WinKey; let title: String
        let from: CGRect; let target: CGRect
        let kind: Planner.Kind?; let before: CGRect; let effective: CGRect; let screenID: CGDirectDisplayID
        let why: String; let isRetry: Bool
    }

    @discardableResult private func reconcile(_ ctx: Context) -> Int {
        records = records.filter { isRunning($0.value.pid) }
        let retries = ctx.isVerification ? pending : [:]
        pending.removeAll()
        var seenNow: [WinKey: CGRect] = [:]
        var jobs: [Job] = []
        var enhancedOff: [AXUIElement] = []

        // 1. Plan every window (reads only).
        for app in ctx.apps {
            let axApp = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(axApp, 0.5)   // a hung app must not stall us
            let jobsBefore = jobs.count
            for w in AX.elements(axApp, kAXWindowsAttribute) {
                guard AX.string(w, kAXRoleAttribute) == kAXWindowRole,
                      AX.string(w, kAXSubroleAttribute) == kAXStandardWindowSubrole,
                      AX.bool(w, kAXMinimizedAttribute) != true,
                      AX.bool(w, "AXFullScreen") != true,
                      let f = AX.frame(w), f.width > 1, f.height > 1,
                      let s = Screens.screen(for: f, in: ctx.screens) else { continue }
                if let ot = onlyTitle, !(AX.string(w, kAXTitleAttribute) ?? "").contains(ot) { continue }
                let key = WinKey(el: w)
                seenNow[key] = f
                if let only = ctx.onlyScreen, s.id != only { continue }
                if let p = retries[key], f.approx(p.seen) {
                    // Untouched since the app overrode us: apply the intended frame again.
                    jobs.append(Job(app: app, w: w, key: key, title: AX.string(w, kAXTitleAttribute) ?? "", from: f, target: p.target,
                                    kind: p.kind, before: p.before, effective: f, screenID: p.screenID,
                                    why: "app undid the change; reapplied", isRetry: true))
                    continue
                }
                var rec = records[key]
                // `effective` = the frame the window had before the system/app reacted to this transition.
                var effective = f
                if let r = rec, !f.approx(r.after) {
                    if let pre = ctx.pre, pre.has(app.pid, r.after) {
                        effective = r.after                      // changed by the app during the Dock move, not by the user
                    } else {
                        // The user changed the window after us: their choice wins, forget it.
                        Log.info("\(app.name) «\(AX.string(w, kAXTitleAttribute) ?? "")» changed since our adjustment (\(r.after.short) → \(f.short)); leaving it alone")
                        records[key] = nil; rec = nil
                    }
                } else if rec == nil, let last = lastSeen[key], !f.approx(last), let pre = ctx.pre, pre.has(app.pid, last) {
                    effective = last                             // app auto-clamped it during the Dock move
                }
                guard let d = Planner.plan(frame: effective, screen: s, dock: ctx.dock, record: rec,
                                           lastReservation: ctx.lastReservation, extendGlued: ctx.extendGlued, scope: ctx.scope),
                      !d.target.approx(f, tol: 0.5),
                      AX.isSettable(w, kAXSizeAttribute) else { continue }
                let title = AX.string(w, kAXTitleAttribute) ?? ""
                if dryRun {
                    Log.info("[dry-run] \(app.name) «\(title)» \(f.short) → \(d.target.short) — \(d.why)"); continue
                }
                let before = (d.kind != nil && rec?.kind == d.kind) ? rec!.before : effective   // keep the original size on retries
                jobs.append(Job(app: app, w: w, key: key, title: title, from: f, target: d.target, kind: d.kind,
                                before: before, effective: effective, screenID: s.id, why: d.why, isRetry: false))
            }
            if jobs.count > jobsBefore, AX.bool(axApp, "AXEnhancedUserInterface") == true {
                // Chromium/Electron animate AX resizes while this is on; turn it off during the change.
                AX.setBool(axApp, "AXEnhancedUserInterface", false); enhancedOff.append(axApp)
            }
        }
        defer { for a in enhancedOff { AX.setBool(a, "AXEnhancedUserInterface", true) } }

        // 2. Animate all windows together, 3. then set the exact final frame and record the outcome.
        if ctx.animate { animate(jobs, duration: ctx.duration) }
        var changed = 0
        for j in jobs {
            let err = apply(j.w, from: AX.frame(j.w) ?? j.from, to: j.target)
            let actual = AX.frame(j.w) ?? j.target
            seenNow[j.key] = actual
            changed += 1
            if j.isRetry {
                if let k = j.kind {
                    records[j.key] = Planner.Record(pid: j.app.pid, kind: k, before: j.before, after: actual, screenID: j.screenID, created: Date())
                } else { records[j.key] = nil }
                Log.info("\(j.app.name) «\(j.title)» \(j.why) → \(actual.short)")
                continue
            }
            if !actual.approx(j.target) {
                // The app is still reacting to the screen change (or enforces a min size): retry once later.
                pending[j.key] = Pending(target: j.target, kind: j.kind, before: j.before, seen: actual, pid: j.app.pid, screenID: j.screenID)
                if err != .success { Log.info("\(j.app.name) «\(j.title)» AXError \(err.rawValue)") }
            }
            if actual.approx(j.from, tol: 0.5) { continue }   // no effect at all: state unchanged
            if let k = j.kind {
                records[j.key] = Planner.Record(pid: j.app.pid, kind: k, before: j.before, after: actual, screenID: j.screenID, created: Date())
            } else {
                records[j.key] = nil
            }
            Log.info("\(j.app.name) «\(j.title)» \(j.from.short)\(j.effective == j.from ? "" : " [before: \(j.effective.short)]") → \(actual.short) — \(j.why)" + (actual.approx(j.target) ? "" : " (app limited it to \(actual.short))"))
        }
        // Keep last-seen frames for visible windows; windows on other Spaces keep their previous entry.
        lastSeen.merge(seenNow) { $1 }
        if lastSeen.count > 2000 { lastSeen = seenNow }
        Log.info("reconcile done: \(changed) window(s) adjusted, \(records.count) record(s)")
        return changed
    }

    static let animationDuration: Double = 0.3

    /// Time-based ease-out interpolation. Every AX resize blocks until the target app has re-laid out the window
    /// (measured ~7–15 ms for Chrome/Finder), so each *app* runs on its own thread at its own pace and a slow app
    /// cannot hold back the others. Never send concurrent AX requests to the same app: it queues them, ours time
    /// out, and the stale steps then land after the final frame. Frames are capped at ~120 Hz.
    private func animate(_ jobs: [Job], duration: Double) {
        guard !jobs.isEmpty else { return }
        let groups = Array(Dictionary(grouping: jobs, by: { $0.app.pid }).values)
        let start = CFAbsoluteTimeGetCurrent()
        DispatchQueue.concurrentPerform(iterations: groups.count) { g in
            let group = groups[g]
            var last = group.map(\.from)
            while true {
                let frameStart = CFAbsoluteTimeGetCurrent()
                let t = (frameStart - start) / duration
                if t >= 1 { break }
                let e = 1 - pow(1 - t, 3)   // ease-out cubic
                for (k, j) in group.enumerated() {
                    let r = CGRect(x: (j.from.minX + (j.target.minX - j.from.minX) * e).rounded(),
                                   y: (j.from.minY + (j.target.minY - j.from.minY) * e).rounded(),
                                   width: (j.from.width + (j.target.width - j.from.width) * e).rounded(),
                                   height: (j.from.height + (j.target.height - j.from.height) * e).rounded())
                    guard r != last[k] else { continue }
                    let moves = r.origin != last[k].origin, resizes = r.size != last[k].size
                    // Shrink before moving and move before growing, so no step pokes past the usable area.
                    if r.width < last[k].width || r.height < last[k].height {
                        if resizes { AX.setSize(j.w, r.size) }; if moves { AX.setPosition(j.w, r.origin) }
                    } else {
                        if moves { AX.setPosition(j.w, r.origin) }; if resizes { AX.setSize(j.w, r.size) }
                    }
                    last[k] = r
                }
                let spent = CFAbsoluteTimeGetCurrent() - frameStart
                // An app this slow would only show a couple of jerky steps: let it jump to the end instead.
                if spent > 0.08 { break }
                if spent < 1.0 / 120 { usleep(useconds_t((1.0 / 120 - spent) * 1_000_000)) }
            }
        }
    }

    private func isRunning(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    /// size → position → size: the first resize keeps the window inside the usable area while it moves (otherwise
    /// AppKit constrains the move against the old, larger size), the last one undoes any clamping done during the move.
    /// Chromium-based apps (Chrome, VS Code, Electron) apply AX resizes asynchronously, clamp sizes that would cross
    /// the display edge, and drop a request equal to the size they last *requested* even when the real size differs.
    /// So verify after a short wait and, if needed, nudge with a 1 pt different size before the exact one.
    @discardableResult private func apply(_ w: AXUIElement, from f: CGRect, to t: CGRect) -> AXError {
        let err = setFrame(w, from: f, to: t)
        if let now = AX.frame(w), now.approx(t, tol: 1) { return err }
        usleep(40_000)   // async apps
        guard let now = AX.frame(w), !now.approx(t, tol: 1) else { return err }
        AX.setSize(w, CGSize(width: t.width, height: t.height - 1))
        setFrame(w, from: now, to: t)
        usleep(40_000)
        if let after = AX.frame(w), !after.approx(t, tol: 1) {
            Log.info("change not accepted by the app: requested \(t.short), got \(after.short)")
        }
        return err
    }

    @discardableResult private func setFrame(_ w: AXUIElement, from f: CGRect, to t: CGRect) -> AXError {
        let moves = abs(f.minX - t.minX) > 0.5 || abs(f.minY - t.minY) > 0.5
        var err = AX.setSize(w, t.size)
        if moves {
            let e = AX.setPosition(w, t.origin); if err == .success { err = e }
            if let now = AX.frame(w), !now.size.equalTo(t.size) { AX.setSize(w, t.size) }
        }
        return err
    }

    func forgetApp(_ pid: pid_t) { queue.async { self.records = self.records.filter { $0.value.pid != pid } } }
}
