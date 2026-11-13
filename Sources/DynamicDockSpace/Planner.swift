import Foundation
import CoreGraphics

/// Pure decision logic (no AX calls), so it is deterministic and idempotent:
/// applying the returned target and planning again yields no further change.
enum Planner {
    enum Kind { case shrunk, extended }
    struct Record { let pid: pid_t; let kind: Kind; let before: CGRect; var after: CGRect; let screenID: CGDirectDisplayID; var created: Date }
    struct Decision { let target: CGRect; let kind: Kind?; let why: String }

    /// Which windows the automation touches (restoring what it changed always happens).
    enum Scope: String, CaseIterable {
        case filling    // only windows that occupy the whole usable area (maximized / "fill")
        case glued      // + windows whose edge is attached to the Dock edge (tiles, halves) — default
        case all        // + windows that were moved and merely reach into the Dock area
        var label: String {
            switch self {
            case .filling: return L("Only windows that fill the usable area")
            case .glued: return L("Maximized and attached to the Dock")
            case .all: return L("Also moved windows that reach the Dock area")
            }
        }
    }

    static let gapTolerance: CGFloat = 16   // tiled-window margins
    static let minKeep: CGFloat = 200       // below this, move the window instead of crushing it

    static func plan(frame f: CGRect, screen s: ScreenInfo, dock: DockState, record: Record?,
                     lastReservation: CGFloat?, extendGlued: Bool, scope: Scope = .glued) -> Decision? {
        let edge = dock.edge
        let reserved = dock.screenID == s.id && dock.reservation > DockDetector.reserveThreshold
            && s.inset(edge) > DockDetector.reserveThreshold
        if reserved {
            if let r = record, r.kind == .extended {
                let t = overlaps(r.before, s, edge) ? shrink(r.before, s, edge) : r.before
                return Decision(target: t, kind: nil, why: "Dock came back: restoring previous size")
            }
            if overlaps(f, s, edge) {   // also retries when an earlier attempt was undone by the app
                if scope == .filling, record == nil, !fills(f, usable(s, edge, dock: nil)) { return nil }
                return Decision(target: shrink(f, s, edge), kind: .shrunk, why: "overlaps the Dock area")
            }
            return nil
        }
        if let r = record, r.kind == .shrunk {
            return Decision(target: clipToDisplay(r.before, s, edge), kind: nil, why: "Dock left: restoring previous size")
        }
        if extendGlued, record == nil, let R = lastReservation, s.inset(edge) <= DockDetector.reserveThreshold {
            switch scope {
            case .filling:
                if fills(f, usable(s, edge, dock: R)), let t = extendIfGlued(f, s, edge, R, minFraction: 0) {
                    return Decision(target: t, kind: .extended, why: "filled the usable area")
                }
            case .glued:
                if let t = extendIfGlued(f, s, edge, R, minFraction: 0.3) {
                    return Decision(target: t, kind: .extended, why: "attached to the edge of the absent Dock")
                }
            case .all:
                if let t = extendIfGlued(f, s, edge, R, minFraction: 0) ?? extendIfReachesZone(f, s, edge, R) {
                    return Decision(target: t, kind: .extended, why: "reaches the area of the absent Dock")
                }
            }
        }
        return nil
    }

    static func overlaps(_ f: CGRect, _ s: ScreenInfo, _ e: DockEdge) -> Bool {
        let v = s.visible
        switch e {
        case .bottom: return f.maxY > v.maxY + 1 && f.minY < s.frame.maxY && f.maxX > v.minX && f.minX < v.maxX
        case .left: return f.minX < v.minX - 1 && f.maxX > s.frame.minX && f.maxY > v.minY && f.minY < v.maxY
        case .right: return f.maxX > v.maxX + 1 && f.minX < s.frame.maxX && f.maxY > v.minY && f.minY < v.maxY
        }
    }

    private static func keptGap(_ g: CGFloat) -> CGFloat { (g >= 0 && g <= gapTolerance) ? g : 0 }

    static func shrink(_ f: CGRect, _ s: ScreenInfo, _ e: DockEdge) -> CGRect {
        let v = s.visible, full = s.frame
        switch e {
        case .bottom:
            let bottom = v.maxY - keptGap(full.maxY - f.maxY)
            if bottom - f.minY >= min(f.height, minKeep) {          // keep the top edge
                return CGRect(x: f.minX, y: f.minY, width: f.width, height: bottom - f.minY)
            }
            let h = min(f.height, bottom - v.minY)                  // too low: lift the window
            return CGRect(x: f.minX, y: bottom - h, width: f.width, height: h)
        case .left:
            let left = v.minX + keptGap(f.minX - full.minX)
            if f.maxX - left >= min(f.width, minKeep) { return CGRect(x: left, y: f.minY, width: f.maxX - left, height: f.height) }
            return CGRect(x: left, y: f.minY, width: min(f.width, v.maxX - left), height: f.height)
        case .right:
            let right = v.maxX - keptGap(full.maxX - f.maxX)
            if right - f.minX >= min(f.width, minKeep) { return CGRect(x: f.minX, y: f.minY, width: right - f.minX, height: f.height) }
            let w = min(f.width, right - v.minX)
            return CGRect(x: right - w, y: f.minY, width: w, height: f.height)
        }
    }

    /// A window whose far edge sits at "display edge − Dock thickness" (± tiling margin) was sized for a Dock
    /// that is no longer there: grow it to the display edge, keeping the same margin.
    static func extendIfGlued(_ f: CGRect, _ s: ScreenInfo, _ e: DockEdge, _ R: CGFloat, minFraction: CGFloat) -> CGRect? {
        let full = s.frame
        switch e {
        case .bottom:
            let g = (full.maxY - R) - f.maxY
            guard g >= -1, g <= gapTolerance, f.minY < full.maxY - R, f.height >= minFraction * s.visible.height else { return nil }
            return CGRect(x: f.minX, y: f.minY, width: f.width, height: full.maxY - max(g, 0) - f.minY)
        case .left:
            let g = f.minX - (full.minX + R)
            guard g >= -1, g <= gapTolerance, f.maxX > full.minX + R, f.width >= minFraction * s.visible.width else { return nil }
            let x = full.minX + max(g, 0)
            return CGRect(x: x, y: f.minY, width: f.maxX - x, height: f.height)
        case .right:
            let gap = (full.maxX - R) - f.maxX
            guard gap >= -1, gap <= gapTolerance, f.minX < full.maxX - R, f.width >= minFraction * s.visible.width else { return nil }
            return CGRect(x: f.minX, y: f.minY, width: full.maxX - max(gap, 0) - f.minX, height: f.height)
        }
    }

    /// Usable area of a display on the Dock side: up to the display edge (`dock == nil`) or with a Dock of
    /// thickness `dock`. The other sides (menu bar…) come from visibleFrame.
    static func usable(_ s: ScreenInfo, _ e: DockEdge, dock R: CGFloat?) -> CGRect {
        let v = s.visible, full = s.frame, r = R ?? 0
        switch e {
        case .bottom: return CGRect(x: v.minX, y: v.minY, width: v.width, height: full.maxY - r - v.minY)
        case .left: return CGRect(x: full.minX + r, y: v.minY, width: v.maxX - full.minX - r, height: v.height)
        case .right: return CGRect(x: v.minX, y: v.minY, width: full.maxX - r - v.minX, height: v.height)
        }
    }

    /// All four edges match the usable area (within the tiling-margin tolerance).
    static func fills(_ f: CGRect, _ u: CGRect) -> Bool {
        abs(f.minX - u.minX) <= gapTolerance && abs(f.maxX - u.maxX) <= gapTolerance
            && abs(f.minY - u.minY) <= gapTolerance && abs(f.maxY - u.maxY) <= gapTolerance
    }

    /// A window (e.g. dragged down a bit) whose Dock-side edge ends inside the strip the Dock used to occupy:
    /// grow it to the display edge.
    static func extendIfReachesZone(_ f: CGRect, _ s: ScreenInfo, _ e: DockEdge, _ R: CGFloat) -> CGRect? {
        let full = s.frame
        switch e {
        case .bottom:
            guard f.maxY >= full.maxY - R - gapTolerance, f.maxY < full.maxY - 0.5, f.minY < full.maxY - R, f.height >= 100 else { return nil }
            return CGRect(x: f.minX, y: f.minY, width: f.width, height: full.maxY - f.minY)
        case .left:
            guard f.minX <= full.minX + R + gapTolerance, f.minX > full.minX + 0.5, f.maxX > full.minX + R, f.width >= 100 else { return nil }
            return CGRect(x: full.minX, y: f.minY, width: f.maxX - full.minX, height: f.height)
        case .right:
            guard f.maxX >= full.maxX - R - gapTolerance, f.maxX < full.maxX - 0.5, f.minX < full.maxX - R, f.width >= 100 else { return nil }
            return CGRect(x: f.minX, y: f.minY, width: full.maxX - f.minX, height: f.height)
        }
    }

    /// A window that had been dragged partly past the Dock-side display edge is restored up to that edge only:
    /// Chromium/Electron refuse sizes that cross the display edge anyway, and nothing past it is visible.
    static func clipToDisplay(_ r: CGRect, _ s: ScreenInfo, _ e: DockEdge) -> CGRect {
        let full = s.frame
        switch e {
        case .bottom: return r.maxY > full.maxY && r.minY < full.maxY ? CGRect(x: r.minX, y: r.minY, width: r.width, height: full.maxY - r.minY) : r
        case .left: return r.minX < full.minX && r.maxX > full.minX ? CGRect(x: full.minX, y: r.minY, width: r.maxX - full.minX, height: r.height) : r
        case .right: return r.maxX > full.maxX && r.minX < full.maxX ? CGRect(x: r.minX, y: r.minY, width: full.maxX - r.minX, height: r.height) : r
        }
    }
}
