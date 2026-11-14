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
        let screens: [ScreenInfo]; let dock: DockState; let lastReservation: CGFloat?; let extendGlued: Bool; let scope: Planner.Scope; var apps: [AppRef]
        let pre: PreSnapshot?; let isVerification: Bool; let animate: Bool
        var onlyScreen: CGDirectDisplayID? = nil; var duration: Double = Engine.animationDuration
        let created = CFAbsoluteTimeGetCurrent()
        var isPrediction: Bool { dock.source == "prediction" }
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
        // On the very last row macOS moves the Dock here after the pointer rests ~160 ms. Shrinking now, before the
        // Dock appears, means it lands on free space. (Chrome, when active, freezes ~0.4 s if the Dock appears over
        // its window, and then snaps it.) If the pointer leaves before the Dock moves, the edge watch undoes it.
        // (The edge watch starts it once the pointer has rested on the last row for `edgeDwell`.)
    }

    static func isAtEdge(_ p: CGPoint, _ s: ScreenInfo, _ e: DockEdge) -> Bool {
        switch e {
        case .bottom: return p.y >= s.frame.maxY - 1
        case .left: return p.x <= s.frame.minX + 1
        case .right: return p.x >= s.frame.maxX - 1
        }
    }

    private func predictEarly(_ target: CGDirectDisplayID) {
        if let p = lastPrediction, p.target == target, Date().timeIntervalSince(p.at) < 2 { return }
        guard let dock = lastDock, settings.enabled, settings.animate, !isStandby, AXIsProcessTrusted(),
              settings.lastReservation(dock.edge) != nil else { return }
        lastPrediction = (target, Date()); earlyTarget = target
        predictArrival(on: target, duration: Self.earlyDuration, why: "pointer pushing against the edge of display \(target)")
    }
    /// Starts ~100 ms before the Dock moves and must end before macOS reserves its area (~350 ms after the pointer
    /// reaches the edge): AppKit apps then clamp windows that still overlap it.
    static let earlyDuration = 0.22
    /// A pointer merely passing over the last row does not summon the Dock (it needs ~160 ms there): wait this long
    /// before shrinking, so passing touches do not resize windows for nothing.
    static let edgeDwell = 0.06

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
    /// Last display the Dock was predicted to arrive on. Only that display is ignored for 2 s (the Dock is already
    /// there, detection just has not caught up): a quick move back to the other display must still be caught.
    private var lastPrediction: (target: CGDirectDisplayID, at: Date)?

    /// "Only with more than one display" is on and a single display is connected.
    var isStandby: Bool { settings.onlyMultiMonitor && lastScreens.count < 2 }

    /// While the pointer rests on the Dock edge of a display without the Dock, watch (≤2 s, 60 Hz, one ~1 ms AX
    /// call) for the Dock starting to move there. Its AXList jumps to the new display ~200 ms before visibleFrame
    /// changes — which is what makes every app clamp its windows abruptly. Shrinking first lets us animate it.
    private var earlyTarget: CGDirectDisplayID?   // early prediction made, Dock not seen moving yet

    private func startEdgeWatch(_ target: CGDirectDisplayID, _ edge: DockEdge) {
        if let p = lastPrediction, p.target == target, Date().timeIntervalSince(p.at) < 2, earlyTarget != target { return }
        guard edgeWatch == nil,
              settings.enabled, settings.animate, !isStandby, AXIsProcessTrusted(),
              settings.lastReservation(edge) != nil else { return }
        let started = Date()
        var atEdgeSince: Date?
        edgeWatch = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            func stop() { t.invalidate(); self.edgeWatch = nil }
            guard Date().timeIntervalSince(started) < 2, let primary = self.lastScreens.first,
                  let s = self.lastScreens.first(where: { $0.id == target }) else { stop(); return }
            if let f = DockDetector.axListFrame(), DockDetector.screenFromAX(f, edge: edge, self.lastScreens)?.id == target {
                stop()
                if self.earlyTarget == target { self.earlyTarget = nil; return }   // already shrunk ahead of the Dock
                self.lastPrediction = (target, Date()); self.predictArrival(on: target); return
            }
            let c = NSEvent.mouseLocation
            let p = CGPoint(x: c.x, y: primary.frame.height - c.y)
            if Self.isAtEdge(p, s, edge) {
                if atEdgeSince == nil { atEdgeSince = Date() }
                if Date().timeIntervalSince(atEdgeSince!) >= Self.edgeDwell { self.predictEarly(target) }
            } else { atEdgeSince = nil }
            if !Self.isNearEdge(p, s, edge) {
                stop()
                if self.earlyTarget == target {
                    // Left the edge before the Dock moved: put the windows back.
                    self.earlyTarget = nil; self.lastPrediction = nil
                    Log.info("pointer left the edge before the Dock moved; undoing the early shrink")
                    self.schedule("early shrink cancelled", after: 0.15)
                }
            }
        }
    }

    /// Shrink windows on the display the Dock is arriving at, using the Dock thickness learned before.
    private func predictArrival(on target: CGDirectDisplayID, duration: Double = 0.2, why: String? = nil) {
        guard let dock = lastDock, let R = settings.lastReservation(dock.edge),
              let s = lastScreens.first(where: { $0.id == target }), NSEvent.pressedMouseButtons == 0 else { return }
        let screens = Self.reserving(R, dock.edge, on: s, in: lastScreens)
        // Only the arriving side: until macOS frees the area the Dock leaves, apps refuse to grow into it.
        let predicted = DockState(edge: dock.edge, autohide: false, screenID: target, reservation: R, source: "prediction", stable: true)
        var ctx = makeContext(screens: screens, dock: predicted, verification: false)
        ctx.onlyScreen = target
        ctx.duration = duration
        Log.info("reconcile [prediction] " + (why ?? "Dock arriving on display \(target)"))
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
        if let stale = dock.staleReservationOn {
            unstableAttempts += 1
            // Give an ordinary Dock move time to finish first.
            if unstableAttempts < 8 { schedule(reason, after: 0.25); return }
            unstableAttempts = 0
            repairs = repairs.filter { Date().timeIntervalSince($0) < 600 }
            if settings.repairDock, repairs.count < 5, Date().timeIntervalSince(repairs.last ?? .distantPast) > 10 { repairDock(stale) }
            else { Log.info("space still reserved on display \(stale) although the Dock is on display \(dock.screenID ?? 0); not repairing (\(settings.repairDock ? "too many recent repairs" : "disabled"))") }
            return
        }
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
        // The Dock changed side (bottom/left/right): first undo what was done for the old side, as if that Dock had
        // left every display (restores shrunk windows, lets windows sized to it grow back), then fit the new side.
        if let old = lastEdge, old != dock.edge {
            let gone = DockState(edge: old, autohide: false, screenID: nil, reservation: 0, source: "Dock moved to another side", stable: true)
            let undo = makeContext(screens: screens, dock: gone, verification: false)
            Log.info("reconcile [Dock side \(old.rawValue) → \(dock.edge.rawValue)] undoing adjustments for the old side")
            queue.async { self.reconcile(undo) }
        }
        lastEdge = dock.edge
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

    private var lastEdge: DockEdge?   // main
    private var repairs: [Date] = []   // recent Dock restarts (a loop guard if a restart ever fails to clear it)
    /// Restarting the Dock (it relaunches by itself in ~1 s) is the only way found to make macOS move a stuck
    /// reservation; afterwards the screen-change notification brings everything back in line.
    private func repairDock(_ stale: CGDirectDisplayID) {
        guard let d = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        repairs.append(Date())
        Log.info("macOS keeps the Dock's space reserved on display \(stale) where the Dock is not: restarting the Dock")
        kill(d.processIdentifier, SIGTERM)
        schedule("after Dock restart", after: 2.5)
    }

    /// Re-check one app's windows (e.g. it was activated: a window may just have been restored from the Dock with a
    /// size from before the Dock moved). Independent of the debounced global pass.
    func refreshApp(_ pid: pid_t) {
        guard settings.enabled, AXIsProcessTrusted(), !isStandby, NSEvent.pressedMouseButtons == 0 else { return }
        let dock = detect()
        guard dock.stable else { return }
        var ctx = makeContext(screens: lastScreens, dock: dock, verification: false)
        ctx.apps = ctx.apps.filter { $0.pid == pid }
        guard !ctx.apps.isEmpty else { return }
        queue.async { self.reconcile(ctx, quiet: true) }
    }

    /// Forget everything (e.g. automation disabled).
    func clearRecords() { queue.async { self.records.removeAll() } }

    private struct Job {
        let app: AppRef; let w: AXUIElement; let key: WinKey; let title: String
        let from: CGRect; let target: CGRect
        let kind: Planner.Kind?; let before: CGRect; let effective: CGRect; let screenID: CGDirectDisplayID
        let why: String; let isRetry: Bool
    }

    @discardableResult private func reconcile(_ ctx: Context, quiet: Bool = false) -> Int {
        let t0 = CFAbsoluteTimeGetCurrent()
        records = records.filter { isRunning($0.value.pid) }
        let retries = ctx.isVerification ? pending : [:]
        pending.removeAll()
        // Every app runs its own pipeline (read → plan → animate → apply) in parallel: an app that is slow to answer
        // (often the active one, busy with the pointer) only delays itself, not the windows of every other app.
        let sh = Shared()
        DispatchQueue.concurrentPerform(iterations: ctx.apps.count) { i in
            let app = ctx.apps[i]
            let ta = CFAbsoluteTimeGetCurrent()
            let jobs = planApp(app, ctx, retries, sh)
            let planned = CFAbsoluteTimeGetCurrent()
            if planned - ta > 0.05 { sh.lock.lock(); sh.notes.append(String(format: "%@ answered in %.0f ms", app.name, (planned - ta) * 1000)); sh.lock.unlock() }
            guard !jobs.isEmpty else { return }
            let axApp = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(axApp, 0.5)
            var enhanced = false
            if AX.bool(axApp, "AXEnhancedUserInterface") == true {
                // Chromium/Electron animate AX resizes while this is on; turn it off during the change.
                AX.setBool(axApp, "AXEnhancedUserInterface", false); enhanced = true
            }
            defer { if enhanced { AX.setBool(axApp, "AXEnhancedUserInterface", true) } }
            if ctx.animate {
                // A prediction must end before macOS reserves the Dock area (apps then clamp their windows): an app
                // that answered late gets a shorter animation rather than a cut-off one.
                let duration = ctx.isPrediction ? max(0.12, ctx.duration - (planned - ctx.created)) : ctx.duration
                animate(jobs, duration: duration)
            }
            for j in jobs { finish(j, ctx, sh) }
        }
        let seenNow = sh.seenNow, changed = sh.changed, notes = sh.notes
        lastSeen.merge(seenNow) { $1 }
        if lastSeen.count > 2000 { lastSeen = seenNow }
        if quiet && changed == 0 { return 0 }
        Log.info(String(format: "reconcile done in %.0f ms (queued %.0f ms): %d window(s) adjusted, %d record(s)", (CFAbsoluteTimeGetCurrent() - t0) * 1000, (t0 - ctx.created) * 1000, changed, records.count) + (notes.isEmpty ? "" : "; slow: " + notes.joined(separator: ", ")))
        return changed
    }

    /// State shared by the per-app pipelines of one pass. `lock` also guards `records`, `pending` and `lastSeen`.
    private final class Shared {
        let lock = NSLock()
        var seenNow: [WinKey: CGRect] = [:]
        var changed = 0
        var notes: [String] = []
    }

    /// Reads one app's windows and decides what to change (AX reads only).
    private func planApp(_ app: AppRef, _ ctx: Context, _ retries: [WinKey: Pending], _ sh: Shared) -> [Job] {
        let lock = sh.lock
        var jobs: [Job] = []
        let axApp = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(axApp, 0.5)   // a hung app must not stall us
        for w in AX.elements(axApp, kAXWindowsAttribute) {
            guard AX.string(w, kAXRoleAttribute) == kAXWindowRole,
                  AX.string(w, kAXSubroleAttribute) == kAXStandardWindowSubrole,
                  AX.bool(w, kAXMinimizedAttribute) != true,
                  AX.bool(w, "AXFullScreen") != true,
                  let f = AX.frame(w), f.width > 1, f.height > 1,
                  let s = Screens.screen(for: f, in: ctx.screens) else { continue }
            if let ot = onlyTitle, !(AX.string(w, kAXTitleAttribute) ?? "").contains(ot) { continue }
            let key = WinKey(el: w)
            lock.lock(); sh.seenNow[key] = f; let last = lastSeen[key]; var rec = records[key]; lock.unlock()
            if let only = ctx.onlyScreen, s.id != only { continue }
            if let p = retries[key], f.approx(p.seen) {
                // Untouched since the app overrode us: apply the intended frame again.
                jobs.append(Job(app: app, w: w, key: key, title: AX.string(w, kAXTitleAttribute) ?? "", from: f, target: p.target,
                                kind: p.kind, before: p.before, effective: f, screenID: p.screenID,
                                why: "app undid the change; reapplied", isRetry: true))
                continue
            }
            // `effective` = the frame the window had before the system/app reacted to this transition.
            var effective = f
            if let r = rec, !f.approx(r.after) {
                if let pre = ctx.pre, pre.has(app.pid, r.after) {
                    effective = r.after                      // changed by the app during the Dock move, not by the user
                } else if Date().timeIntervalSince(r.created) < 2.5 {
                    // Moments after our own change, while the Dock was still settling: the system/app nudged it
                    // (e.g. clamped a few points when macOS reserved the area). Fit it again from the original size.
                    effective = r.kind == .shrunk ? r.before : r.after
                } else {
                    // The user changed the window after us: their choice wins, forget it.
                    Log.info("\(app.name) «\(AX.string(w, kAXTitleAttribute) ?? "")» changed since our adjustment (\(r.after.short) → \(f.short)); leaving it alone")
                    lock.lock(); records[key] = nil; lock.unlock(); rec = nil
                }
            } else if rec == nil, let last, !f.approx(last), let pre = ctx.pre, pre.has(app.pid, last) {
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
        return jobs
    }

    /// Sets the exact final frame and records the outcome.
    private func finish(_ j: Job, _ ctx: Context, _ sh: Shared) {
        // Ahead of the Dock, Chromium/Electron refuse to grow into the area macOS still reserves: no nudging then,
        // the regular pass grows them once the area is free.
        let err = apply(j.w, from: AX.frame(j.w) ?? j.from, to: j.target, nudge: !ctx.isPrediction)
        let actual = AX.frame(j.w) ?? j.target
        sh.lock.lock(); defer { sh.lock.unlock() }
        sh.seenNow[j.key] = actual
        sh.changed += 1
        if j.isRetry {
            if let k = j.kind {
                records[j.key] = Planner.Record(pid: j.app.pid, kind: k, before: j.before, after: actual, screenID: j.screenID, created: Date())
            } else { records[j.key] = nil }
            Log.info("\(j.app.name) «\(j.title)» \(j.why) → \(actual.short)")
            return
        }
        if !actual.approx(j.target) {
            // The app is still reacting to the screen change (or enforces a min size): retry once later.
            pending[j.key] = Pending(target: j.target, kind: j.kind, before: j.before, seen: actual, pid: j.app.pid, screenID: j.screenID)
            if err != .success { Log.info("\(j.app.name) «\(j.title)» AXError \(err.rawValue)") }
        }
        if actual.approx(j.from, tol: 0.5) { return }   // no effect at all: state unchanged
        if let k = j.kind {
            records[j.key] = Planner.Record(pid: j.app.pid, kind: k, before: j.before, after: actual, screenID: j.screenID, created: Date())
        } else {
            records[j.key] = nil
        }
        Log.info("\(j.app.name) «\(j.title)» \(j.from.short)\(j.effective == j.from ? "" : " [before: \(j.effective.short)]") → \(actual.short) — \(j.why)" + (actual.approx(j.target) ? "" : " (app limited it to \(actual.short))"))
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
        let statsLock = NSLock(); var stats: [String] = []
        DispatchQueue.concurrentPerform(iterations: groups.count) { g in
            let group = groups[g]
            var last = group.map(\.from)
            var done = Set<Int>()                 // windows the app resized by itself while it was stalled
            var paused = 0.0                      // time the app spent stalled; the animation clock stops meanwhile
            var steps = 0, total = 0.0, worst = 0.0, stalls = 0, bailed = false
            defer {
                let line = String(format: "%@ ×%d: %d steps, avg %.1f ms, max %.1f ms%@%@", group[0].app.name, group.count, steps,
                                  steps > 0 ? total / Double(steps) * 1000 : 0, worst * 1000,
                                  stalls > 0 ? String(format: ", %d stall(s) waited out (%.0f ms)", stalls, paused * 1000) : "",
                                  bailed ? ", unresponsive → jumped to the end" : "")
                statsLock.lock(); stats.append(line); statsLock.unlock()
            }
            while true {
                let frameStart = CFAbsoluteTimeGetCurrent()
                let t = (frameStart - start - paused) / duration
                if t >= 1 || done.count == group.count { break }
                let e = 1 - pow(1 - t, 3)   // ease-out cubic
                for (k, j) in group.enumerated() where !done.contains(k) {
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
                steps += 1; total += spent; worst = max(worst, spent)
                if spent > 0.08 {
                    // The app stopped responding for a moment. Chrome does this for ~0.3–0.5 s when it is the active app
                    // and the Dock arrives on its display. Jumping to the end would show as a snap: instead stop the
                    // clock for the stall and carry on from where the window is, unless the app resized it meanwhile.
                    stalls += 1
                    paused += spent - 1.0 / 120
                    if spent > 1 || paused > 1.5 { bailed = true; break }
                    for (k, j) in group.enumerated() where !done.contains(k) {
                        if let f = AX.frame(j.w), f.approx(j.target, tol: 1) || !f.approx(last[k], tol: 2) { done.insert(k) }
                    }
                    continue
                }
                if spent < 1.0 / 120 { usleep(useconds_t((1.0 / 120 - spent) * 1_000_000)) }
            }
        }
        Log.info(String(format: "animation %.0f ms (planned %.0f): ", (CFAbsoluteTimeGetCurrent() - start) * 1000, duration * 1000) + stats.joined(separator: " | "))
    }

    private func isRunning(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    /// size → position → size: the first resize keeps the window inside the usable area while it moves (otherwise
    /// AppKit constrains the move against the old, larger size), the last one undoes any clamping done during the move.
    /// Chromium-based apps (Chrome, VS Code, Electron) apply AX resizes asynchronously, clamp sizes that would cross
    /// the display edge, and drop a request equal to the size they last *requested* even when the real size differs.
    /// So verify after a short wait and, if needed, nudge with a 1 pt different size before the exact one.
    @discardableResult private func apply(_ w: AXUIElement, from f: CGRect, to t: CGRect, nudge: Bool = true) -> AXError {
        let err = setFrame(w, from: f, to: t)
        if !nudge { return err }
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
