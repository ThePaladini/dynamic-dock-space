import Foundation

final class Settings {
    private let d = UserDefaults.standard
    init() {
        d.register(defaults: ["enabled": true, "extendGlued": true, "animate": true, "onlyMultiMonitor": true, "scope": "glued", "repairDock": true, "excludedBundleIDs": [String]()])
    }
    var enabled: Bool { get { d.bool(forKey: "enabled") } set { d.set(newValue, forKey: "enabled") } }
    /// Expand windows that were sized up to the Dock edge on a display that no longer has the Dock.
    var extendGlued: Bool { get { d.bool(forKey: "extendGlued") } set { d.set(newValue, forKey: "extendGlued") } }
    /// Animate window changes instead of jumping to the final frame.
    var animate: Bool { get { d.bool(forKey: "animate") } set { d.set(newValue, forKey: "animate") } }
    /// Act only while more than one display is connected.
    var onlyMultiMonitor: Bool { get { d.bool(forKey: "onlyMultiMonitor") } set { d.set(newValue, forKey: "onlyMultiMonitor") } }
    /// Restart the Dock when macOS keeps reserving its space on a display it left (only a Dock restart clears it).
    var repairDock: Bool { get { d.bool(forKey: "repairDock") } set { d.set(newValue, forKey: "repairDock") } }
    var scope: Planner.Scope {
        get { Planner.Scope(rawValue: d.string(forKey: "scope") ?? "") ?? .glued }
        set { d.set(newValue.rawValue, forKey: "scope") }
    }
    var excluded: [String] { get { d.stringArray(forKey: "excludedBundleIDs") ?? [] } set { d.set(newValue.sorted(), forKey: "excludedBundleIDs") } }
    func lastReservation(_ e: DockEdge) -> CGFloat? {
        let v = d.double(forKey: "lastReservation." + e.rawValue); return v > 0 ? CGFloat(v) : nil
    }
    func setLastReservation(_ v: CGFloat, _ e: DockEdge) { d.set(Double(v), forKey: "lastReservation." + e.rawValue) }
}
