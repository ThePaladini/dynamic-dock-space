import AppKit

/// Snapshot of one display, in global CG coordinates (origin top-left of the primary display, y down),
/// which is the coordinate space used by the Accessibility API.
struct ScreenInfo: Equatable {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let visible: CGRect
    let isBuiltin: Bool

    func inset(_ edge: DockEdge) -> CGFloat {
        switch edge {
        case .bottom: return frame.maxY - visible.maxY
        case .left: return visible.minX - frame.minX
        case .right: return frame.maxX - visible.maxX
        }
    }
}

enum Screens {
    /// Must be called on the main thread. Reads NSScreen fresh each time (visibleFrame is re-evaluated by AppKit).
    static func snapshot() -> [ScreenInfo] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let primaryMaxY = primary.frame.maxY
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: primaryMaxY - r.maxY, width: r.width, height: r.height) }
        return screens.compactMap { s in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = n.uint32Value
            return ScreenInfo(id: id, name: s.localizedName, frame: flip(s.frame), visible: flip(s.visibleFrame),
                              isBuiltin: CGDisplayIsBuiltin(id) != 0)
        }
    }

    /// Screen holding the largest part of the rect (falls back to the nearest center).
    static func screen(for r: CGRect, in screens: [ScreenInfo]) -> ScreenInfo? {
        var best: ScreenInfo?
        var bestArea: CGFloat = 0
        for s in screens {
            let i = s.frame.intersection(r)
            if !i.isNull, i.width * i.height > bestArea { bestArea = i.width * i.height; best = s }
        }
        if best != nil { return best }
        let c = CGPoint(x: r.midX, y: r.midY)
        return screens.min { hypot($0.frame.midX - c.x, $0.frame.midY - c.y) < hypot($1.frame.midX - c.x, $1.frame.midY - c.y) }
    }

    static func screen(containing p: CGPoint, in screens: [ScreenInfo]) -> ScreenInfo? {
        screens.first { $0.frame.contains(p) }
    }
}
