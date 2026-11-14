import CoreGraphics
import Foundation
// usage: mouse x y  -> slow move of the pointer to the bottom edge at x, ending at y, then keeps pushing down
let a = CommandLine.arguments
let x = Double(a[1])!, y = Double(a[2])!
func post(_ p: CGPoint, dy: Int64) {
    let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
    e?.setIntegerValueField(.mouseEventDeltaY, value: dy)
    e?.post(tap: .cghidEventTap)
}
for i in 0..<25 { post(CGPoint(x: x, y: y - 60 + Double(i) * 2.5), dy: 3); usleep(40_000) }
for _ in 0..<25 { post(CGPoint(x: x, y: y), dy: 4); usleep(40_000) }
