import AppKit
import ApplicationServices

enum AX {
    static func raw(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }
    static func string(_ el: AXUIElement, _ attr: String) -> String? { raw(el, attr) as? String }
    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? { (raw(el, attr) as? NSNumber)?.boolValue }
    static func elements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
        guard let v = raw(el, attr), CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
        return (v as! [AnyObject]).compactMap { o in CFGetTypeID(o) == AXUIElementGetTypeID() ? (o as! AXUIElement) : nil }
    }
    private static func axValue(_ el: AXUIElement, _ attr: String) -> AXValue? {
        guard let v = raw(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return (v as! AXValue)
    }
    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let pv = axValue(el, kAXPositionAttribute), let sv = axValue(el, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv, .cgPoint, &p), AXValueGetValue(sv, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
    static func isSettable(_ el: AXUIElement, _ attr: String) -> Bool {
        var b = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(el, attr as CFString, &b) == .success && b.boolValue
    }
    @discardableResult static func setPosition(_ el: AXUIElement, _ p: CGPoint) -> AXError {
        var p = p
        return AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
    }
    @discardableResult static func setSize(_ el: AXUIElement, _ s: CGSize) -> AXError {
        var s = s
        return AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)
    }
    static func setBool(_ el: AXUIElement, _ attr: String, _ v: Bool) {
        AXUIElementSetAttributeValue(el, attr as CFString, (v ? kCFBooleanTrue : kCFBooleanFalse)!)
    }
}
