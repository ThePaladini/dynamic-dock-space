import AppKit
import ApplicationServices
// axtime <pid> [rounds]: time each AX read the engine's planner makes on that app's windows
setvbuf(stdout, nil, _IOLBF, 0)
let pid = pid_t(CommandLine.arguments[1])!, rounds = Int(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "3")!
let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app, 1)
func time(_ name: String, _ f: () -> Void) -> String { let t = CFAbsoluteTimeGetCurrent(); f(); return String(format: "%@ %.1f", name, (CFAbsoluteTimeGetCurrent() - t) * 1000) }
func read(_ e: AXUIElement, _ a: String) { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, a as CFString, &v) }
for _ in 0..<rounds {
    var out: [String] = []
    var wins: [AXUIElement] = []
    out.append(time("windows") { var v: CFTypeRef?; AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v); wins = (v as? [AXUIElement]) ?? [] })
    for w in wins {
        for a in [kAXRoleAttribute, kAXSubroleAttribute, kAXMinimizedAttribute, "AXFullScreen", kAXPositionAttribute, kAXSizeAttribute, kAXTitleAttribute] as [String] {
            out.append(time(a.replacingOccurrences(of: "AX", with: "")) { read(w, a) })
        }
        out.append(time("settable") { var b: DarwinBoolean = false; AXUIElementIsAttributeSettable(w, kAXSizeAttribute as CFString, &b) })
    }
    out.append(time("enhancedUI") { read(app, "AXEnhancedUserInterface") })
    print(out.joined(separator: "  "))
    usleep(300_000)
}
