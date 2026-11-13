import CoreGraphics
import Foundation
// usage: mouse x y  -> slow drag of the pointer to the bottom edge at x, ending at y
let a = CommandLine.arguments
let x = Double(a[1])!, y = Double(a[2])!
for i in 0..<25 {
    let p = CGPoint(x: x, y: y - 60 + Double(i) * 2.5)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(40_000)
}
for _ in 0..<15 { CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?.post(tap: .cghidEventTap); usleep(60_000) }
