import CoreGraphics
import Foundation
// glide x0 y0 x1 y1 ms : human-like pointer sweep (ease-in-out, 120 Hz, with deltas), then pushes against the edge
let a = CommandLine.arguments.dropFirst().map { Double($0)! }
let (x0, y0, x1, y1, ms) = (a[0], a[1], a[2], a[3], a[4])
var last = CGPoint(x: x0, y: y0)
let pushDY = Int64(ProcessInfo.processInfo.environment["PUSHDY"] ?? "1")!
func post(_ p: CGPoint) {
    let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
    e?.setIntegerValueField(.mouseEventDeltaX, value: Int64(p.x - last.x))
    e?.setIntegerValueField(.mouseEventDeltaY, value: Int64(max(p.y - last.y, CGFloat(pushDY))))
    e?.post(tap: .cghidEventTap); last = p
}
let n = Int(ms / 1000 * 120)
for i in 0...n {
    let t = Double(i) / Double(n), e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    post(CGPoint(x: x0 + (x1 - x0) * e, y: y0 + (y1 - y0) * e)); usleep(8_333)
}
for _ in 0..<60 { post(CGPoint(x: x1, y: y1)); usleep(16_000) }
