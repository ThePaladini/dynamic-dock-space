import AppKit
// Renders the app icon (1024×1024 PNG). Usage: make-icon <out.png>
let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
func c(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
func rr(_ r: NSRect, _ rad: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad) }

// Background squircle (macOS icon grid: 824 px body centered in 1024 canvas)
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bg = rr(body, 185)
NSGraphicsContext.current!.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowColor = c(0x000000, 0.35); shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.set(); c(0x0B1B3F).setFill(); bg.fill()
NSGraphicsContext.current!.restoreGraphicsState()
NSGradient(colors: [c(0x1D4ED8), c(0x0EA5E9), c(0x22D3EE)], atLocations: [0, 0.65, 1], colorSpace: .sRGB)!.draw(in: bg, angle: 60)
// soft top highlight
NSGradient(colors: [c(0xFFFFFF, 0), c(0xFFFFFF, 0.20)])!.draw(in: rr(NSRect(x: 100, y: 520, width: 824, height: 404), 185), angle: 90)

// Two monitors
func monitor(x: CGFloat, hasDock: Bool) {
    let frame = NSRect(x: x, y: 400, width: 330, height: 236)
    // stand
    c(0xE2E8F0).setFill()
    rr(NSRect(x: frame.midX - 22, y: 330, width: 44, height: 80), 8).fill()
    rr(NSRect(x: frame.midX - 75, y: 316, width: 150, height: 26), 13).fill()
    // bezel + screen
    c(0xF8FAFC).setFill(); rr(frame, 26).fill()
    let screen = frame.insetBy(dx: 16, dy: 16)
    c(0x0F172A).setFill(); rr(screen, 12).fill()
    // menu bar
    c(0x334155).setFill(); NSBezierPath(rect: NSRect(x: screen.minX, y: screen.maxY - 14, width: screen.width, height: 14)).fill()
    let dockH: CGFloat = hasDock ? 34 : 0
    // window filling the usable area
    let win = NSRect(x: screen.minX + 10, y: screen.minY + 8 + dockH, width: screen.width - 20, height: screen.height - 30 - dockH)
    c(0xE0F2FE).setFill(); rr(win, 8).fill()
    c(0x7DD3FC).setFill(); rr(NSRect(x: win.minX, y: win.maxY - 16, width: win.width, height: 16), 8).fill()
    for (i, col) in [0xF87171, 0xFBBF24, 0x34D399].enumerated() {
        c(UInt32(col)).setFill(); NSBezierPath(ovalIn: NSRect(x: win.minX + 8 + CGFloat(i) * 14, y: win.maxY - 12, width: 9, height: 9)).fill()
    }
    if hasDock {
        let dock = NSRect(x: screen.midX - 88, y: screen.minY + 5, width: 176, height: 30)
        c(0xFFFFFF, 0.92).setFill(); rr(dock, 12).fill()
        for (i, col) in [0x2563EB, 0x22C55E, 0xF59E0B, 0xEF4444, 0xA855F7].enumerated() {
            c(UInt32(col)).setFill(); rr(NSRect(x: dock.minX + 12 + CGFloat(i) * 32, y: dock.minY + 5, width: 22, height: 20), 6).fill()
        }
    }
}
monitor(x: 158, hasDock: false)
monitor(x: 536, hasDock: true)

// Arrow: the Dock travelling from the left display to the right one
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 330, y: 700))
arrow.curve(to: NSPoint(x: 690, y: 700), controlPoint1: NSPoint(x: 410, y: 820), controlPoint2: NSPoint(x: 610, y: 820))
arrow.lineWidth = 30; arrow.lineCapStyle = .round
c(0xFFFFFF).setStroke(); arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 725, y: 668)); head.line(to: NSPoint(x: 640, y: 680)); head.line(to: NSPoint(x: 700, y: 748)); head.close()
c(0xFFFFFF).setFill(); head.fill()
head.lineWidth = 12; head.lineJoinStyle = .round; head.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
