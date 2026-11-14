import CoreGraphics
import Foundation
// trace <pid> <secs> : logs every change of the on-screen height of <pid>'s largest layer-0 window (WindowServer's view)
setvbuf(stdout, nil, _IOLBF, 0)
let a = CommandLine.arguments
let pid = Int(a[1])!, secs = Double(a[2])!
let start = CFAbsoluteTimeGetCurrent()
var last = -1.0
while CFAbsoluteTimeGetCurrent() - start < secs {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    var best: CGRect?
    for w in list where (w[kCGWindowOwnerPID as String] as? Int) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
        if let d = w[kCGWindowBounds as String], let b = CGRect(dictionaryRepresentation: d as! CFDictionary), b.width > 500 {
            if best == nil || b.width * b.height > best!.width * best!.height { best = b }
        }
    }
    if let b = best, b.height != last {
        print(String(format: "%.4f %.0f", CFAbsoluteTimeGetCurrent() - start, b.height)); last = b.height
    }
    usleep(4_000)
}
