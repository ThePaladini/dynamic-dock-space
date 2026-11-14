import AppKit
import ApplicationServices

final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let engine: Engine
    private let settings: Settings

    init(engine: Engine, settings: Settings) {
        self.engine = engine; self.settings = settings
        super.init()
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        item.menu = menu
        refreshIcon()
    }

    func refreshIcon() {
        let trusted = AXIsProcessTrusted()
        let name = !trusted ? "exclamationmark.triangle" : ((settings.enabled && !engine.isStandby) ? "dock.rectangle" : "rectangle.dashed")
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Dynamic Dock Space")
            ?? NSImage(systemSymbolName: "rectangle.bottomthird.inset.filled", accessibilityDescription: nil)
        img?.isTemplate = true
        item.button?.image = img
        item.button?.toolTip = "Dynamic Dock Space" + (trusted ? "" : L(" — Accessibility permission missing"))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let dock = engine.detect()
        let screens = engine.lastScreens
        let trusted = AXIsProcessTrusted()

        menu.addItem(header("Dynamic Dock Space"))
        let toggle = action(L("Automation enabled"), #selector(toggleEnabled)); toggle.state = settings.enabled ? .on : .off
        menu.addItem(toggle)
        let multi = action(L("Only with more than one display"), #selector(toggleMulti)); multi.state = settings.onlyMultiMonitor ? .on : .off
        multi.indentationLevel = 1
        menu.addItem(multi)
        if settings.enabled && engine.isStandby { menu.addItem(info("    " + L("Standby: only one display connected"))) }
        menu.addItem(.separator())

        let dockScreen = screens.first { $0.id == dock.screenID }
        var dockLine = String(format: L("Dock: %@"), dockScreen.map { label(for: $0, in: screens) } ?? L("not identified"))
        dockLine += " · " + dock.edge.label
        dockLine += " · " + (dock.autohide ? L("auto-hidden") : (dock.reservation > 0 ? String(format: L("reserves %d pt"), Int(dock.reservation)) : L("in transition")))
        menu.addItem(info(dockLine))
        menu.addItem(info(String(format: L("Displays (%d):"), screens.count)))
        for s in screens {
            let mark = s.id == dock.screenID ? "  ▸ " : "     "
            menu.addItem(info(mark + label(for: s, in: screens) + "  \(Int(s.frame.width))×\(Int(s.frame.height)) pt" + (s.id == dock.screenID ? "  — Dock" : "")))
        }
        menu.addItem(.separator())

        let now = action(L("Adjust windows now"), #selector(adjustNow)); now.isEnabled = trusted && settings.enabled
        menu.addItem(now)
        let scopeItem = NSMenuItem(title: L("Windows to adjust"), action: nil, keyEquivalent: "")
        let scopeMenu = NSMenu(); scopeMenu.autoenablesItems = false
        for sc in Planner.Scope.allCases {
            let it = action(sc.label + (sc == .glued ? " " + L("(default)") : ""), #selector(setScope(_:)))
            it.representedObject = sc.rawValue; it.state = settings.scope == sc ? .on : .off
            scopeMenu.addItem(it)
        }
        scopeItem.submenu = scopeMenu
        menu.addItem(scopeItem)
        let ext = action(L("Expand windows on displays without the Dock"), #selector(toggleExtend)); ext.state = settings.extendGlued ? .on : .off
        menu.addItem(ext)
        let anim = action(L("Animate resizing"), #selector(toggleAnimate)); anim.state = settings.animate ? .on : .off
        menu.addItem(anim)
        let rep = action(L("Repair stuck Dock space (restarts the Dock)"), #selector(toggleRepair)); rep.state = settings.repairDock ? .on : .off
        menu.addItem(rep)

        // Ignored apps
        let ignored = NSMenuItem(title: L("Ignored apps"), action: nil, keyEquivalent: "")
        let sub = NSMenu(); sub.autoenablesItems = false
        if let front = NSWorkspace.shared.frontmostApplication, let b = front.bundleIdentifier,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier, !settings.excluded.contains(b) {
            let it = action(String(format: L("Ignore %@"), front.localizedName ?? b), #selector(toggleIgnore(_:))); it.representedObject = b
            sub.addItem(it); sub.addItem(.separator())
        }
        if settings.excluded.isEmpty { sub.addItem(info(L("None (click an app to toggle)"))) }
        for b in settings.excluded {
            let it = action(appName(b), #selector(toggleIgnore(_:))); it.representedObject = b; it.state = .on
            sub.addItem(it)
        }
        sub.addItem(.separator())
        let addMenu = NSMenu(); addMenu.autoenablesItems = false
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for a in running {
            let it = action(a.localizedName ?? a.bundleIdentifier!, #selector(toggleIgnore(_:)))
            it.representedObject = a.bundleIdentifier; it.state = settings.excluded.contains(a.bundleIdentifier!) ? .on : .off
            addMenu.addItem(it)
        }
        let addItem = NSMenuItem(title: L("Running apps"), action: nil, keyEquivalent: ""); addItem.submenu = addMenu
        sub.addItem(addItem)
        ignored.submenu = sub
        menu.addItem(ignored)

        let login = action(L("Launch at login"), #selector(toggleLogin)); login.state = LoginItem.isEnabled ? .on : .off
        if LoginItem.status == .requiresApproval { login.title += " " + L("(approve in System Settings)") }
        menu.addItem(login)
        menu.addItem(.separator())
        if trusted {
            menu.addItem(info(L("Accessibility: allowed")))
        } else {
            menu.addItem(action(L("Grant Accessibility permission…"), #selector(openAccessibility)))
        }
        menu.addItem(action(L("Quit"), #selector(quit), key: "q"))
    }

    // MARK: helpers
    private func header(_ t: String) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        i.attributedTitle = NSAttributedString(string: t, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        i.isEnabled = false; return i
    }
    private func info(_ t: String) -> NSMenuItem { let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; return i }
    private func action(_ t: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: t, action: sel, keyEquivalent: key); i.target = self; return i
    }
    private func label(for s: ScreenInfo, in all: [ScreenInfo]) -> String {
        s.isBuiltin ? L("Built-in Display") : s.name
    }
    private func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    // MARK: actions
    @objc private func toggleEnabled() {
        settings.enabled.toggle()
        if settings.enabled { engine.schedule("enabled", after: 0.1) } else { engine.clearRecords() }
        engine.updatePointerMonitor()
        refreshIcon()
    }
    @objc private func toggleExtend() { settings.extendGlued.toggle(); engine.schedule("option changed", after: 0.1) }
    @objc private func toggleMulti() {
        settings.onlyMultiMonitor.toggle(); engine.updatePointerMonitor(); refreshIcon(); engine.schedule("option changed", after: 0.1)
    }
    @objc private func setScope(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let sc = Planner.Scope(rawValue: raw) else { return }
        settings.scope = sc; engine.schedule("option changed", after: 0.1)
    }
    @objc private func toggleRepair() { settings.repairDock.toggle() }
    @objc private func toggleAnimate() { settings.animate.toggle() }
    @objc private func adjustNow() { engine.schedule("manual", after: 0.05) }
    @objc private func toggleIgnore(_ sender: NSMenuItem) {
        guard let b = sender.representedObject as? String else { return }
        var list = settings.excluded
        if let i = list.firstIndex(of: b) { list.remove(at: i) } else { list.append(b) }
        settings.excluded = list
    }
    @objc private func toggleLogin() {
        do { try LoginItem.set(!LoginItem.isEnabled) } catch {
            let a = NSAlert(); a.messageText = L("Could not change launch at login")
            a.informativeText = error.localizedDescription + "\n\n" + L("The app must be in /Applications or ~/Applications.")
            a.runModal()
        }
        if LoginItem.status == .requiresApproval { LoginItem.openSettings() }
    }
    @objc private func openAccessibility() { Permissions.request(); }
    @objc private func quit() { NSApp.terminate(nil) }
}
